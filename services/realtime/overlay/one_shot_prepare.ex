defmodule Realtime.OneShotPrepare do
  @moduledoc false

  alias Realtime.Api.Tenant
  alias Realtime.Repo

  @default_jwt_secret "super-secret-jwt-token-with-at-least-32-characters-long"
  @default_tenant "realtime-dev"
  @seed_gcm_backfill_flag true

  def run do
    assert_realtime_stopped!()
    Application.load(:realtime)
    start_required_dependencies!()
    check_crypto_config!()

    Realtime.Release.migrate()

    {:ok, repo_pid} = Repo.start_link()

    try do
      maybe_seed_gcm_backfill_flag!()
      tenant = seed_tenant!()
      tenant = migrate_tenant!(tenant)
      maintain_tenant_database!(tenant)
    after
      GenServer.stop(repo_pid)
    end

    assert_realtime_stopped!()
    :ok
  end

  defp start_required_dependencies! do
    for app <- [:crypto, :ecto_sql, :postgrex] do
      {:ok, _started} = Application.ensure_all_started(app)
    end
  end

  defp check_crypto_config! do
    Code.ensure_loaded!(Realtime.Crypto)

    if function_exported?(Realtime.Crypto, :check_config, 0) do
      :ok = Realtime.Crypto.check_config()
    end
  end

  defp seed_tenant! do
    tenant_name = System.get_env("SELF_HOST_TENANT_NAME", @default_tenant)

    {:ok, tenant} =
      Repo.transaction(fn ->
        case Repo.get_by(Tenant, external_id: tenant_name) do
          %Tenant{} = existing -> Repo.delete!(existing)
          nil -> :ok
        end

        %Tenant{}
        |> Tenant.changeset(%{
          "name" => tenant_name,
          "external_id" => tenant_name,
          "jwt_secret" => System.get_env("API_JWT_SECRET", @default_jwt_secret),
          "jwt_jwks" => decode_jwks(),
          "extensions" => [
            %{
              "type" => "postgres_cdc_rls",
              "settings" => %{
                "db_name" => System.get_env("DB_NAME", "postgres"),
                "db_host" => System.get_env("DB_HOST", "host.docker.internal"),
                "db_user" => System.get_env("DB_USER", "supabase_admin"),
                "db_password" => System.get_env("DB_PASSWORD", "postgres"),
                "db_port" => System.get_env("DB_PORT", "5433"),
                "region" => "us-east-1",
                "poll_interval_ms" => 100,
                "poll_max_record_bytes" => 1_048_576,
                "ssl_enforced" => false
              }
            }
          ]
        })
        |> Repo.insert!()
      end)

    tenant
  end

  defp decode_jwks do
    case System.get_env("API_JWT_JWKS") do
      nil -> nil
      value -> Jason.decode!(value)
    end
  end

  defp maybe_seed_gcm_backfill_flag! do
    if @seed_gcm_backfill_flag do
      %Realtime.Api.FeatureFlag{}
      |> Realtime.Api.FeatureFlag.changeset(%{name: "gcm_encryption_backfill", enabled: true})
      |> Repo.insert(
        on_conflict: {:replace, [:enabled, :rollout_percentage, :bucket_key, :updated_at]},
        conflict_target: :name,
        returning: true
      )
      |> case do
        {:ok, _flag} -> :ok
        {:error, reason} -> raise "could not seed gcm_encryption_backfill: #{inspect(reason)}"
      end
    end
  end

  defp migrate_tenant!(tenant) do
    tenant = Repo.preload(tenant, :extensions)
    extension =
      tenant
      |> Map.fetch!(:extensions)
      |> Enum.find(&(&1.type == "postgres_cdc_rls"))

    unless extension, do: raise("seeded tenant has no postgres_cdc_rls extension")

    case Realtime.Tenants.Migrations.migrate(tenant.external_id, extension.settings, tenant.migrations_ran) do
      {:ok, migrations_ran} ->
        tenant |> Tenant.changeset(%{migrations_ran: migrations_ran}) |> Repo.update!()

      {:error, reason} ->
        raise "tenant migrations failed: #{inspect(reason)}"
    end
  end

  defp maintain_tenant_database!(tenant) do
    {:ok, conn} = Realtime.Database.connect(tenant, "realtime_janitor", :stop)

    try do
      Realtime.Messages.delete_old_messages(conn)
      create_messages_partitions!(conn)
    after
      GenServer.stop(conn)
    end
  end

  defp create_messages_partitions!(conn) do
    today = Date.utc_today()

    Date.range(Date.add(today, -1), Date.add(today, 3))
    |> Enum.each(fn date ->
      name = "messages_#{Date.to_iso8601(date) |> String.replace("-", "_")}"
      start_date = Date.to_string(date)
      end_date = Date.to_string(Date.add(date, 1))

      queries = [
        "CREATE TABLE IF NOT EXISTS realtime.#{name} PARTITION OF realtime.messages FOR VALUES FROM ('#{start_date}') TO ('#{end_date}')",
        "ALTER TABLE realtime.#{name} OWNER TO supabase_realtime_admin"
      ]

      Enum.each(queries, fn query ->
        case Postgrex.query(conn, query, []) do
          {:ok, _result} -> :ok
          {:error, reason} -> raise "could not prepare tenant partition #{name}: #{inspect(reason)}"
        end
      end)
    end)
  end

  defp assert_realtime_stopped! do
    if Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :realtime end) do
      raise "one-shot preparation must not start the Realtime application"
    end
  end
end
