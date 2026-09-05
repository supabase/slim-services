defmodule SupabaseCli.ProvisionTenant do
  defp required_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> raise "missing required environment variable #{name}"
    end
  end

  defp integer_env!(name) do
    value = required_env!(name)

    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> raise "environment variable #{name} must be a non-negative integer"
    end
  end

  def run do
    {:ok, _} = Application.ensure_all_started(:supavisor)

    {:ok, version} =
      case Supavisor.Repo.query!("select version()") do
        %{rows: [[postgres_version]]} -> Supavisor.Helpers.parse_pg_version(postgres_version)
        _ -> nil
      end

    default_pool_size = integer_env!("DEFAULT_POOL_SIZE")

    params = %{
      "external_id" => required_env!("TENANT_ID"),
      "db_host" => required_env!("POSTGRES_HOST"),
      "db_port" => integer_env!("POSTGRES_PORT"),
      "db_database" => "postgres",
      "require_user" => false,
      "auth_query" => "SELECT * FROM pgbouncer.get_auth($1)",
      "default_max_clients" => integer_env!("MAX_CLIENT_CONN"),
      "default_pool_size" => default_pool_size,
      "default_parameter_status" => %{"server_version" => version},
      "users" => [
        %{
          "db_user" => "pgbouncer",
          "db_password" => required_env!("POSTGRES_PASSWORD"),
          "mode_type" => required_env!("POOL_MODE"),
          "pool_size" => default_pool_size,
          "is_manager" => true
        }
      ]
    }

    case Supavisor.Tenants.get_tenant_by_external_id(params["external_id"]) do
      nil ->
        {:ok, _} = Supavisor.Tenants.create_tenant(params)

      existing ->
        existing = Supavisor.Repo.preload(existing, :users)
        {:ok, _} = Supavisor.Tenants.update_tenant(existing, params)
    end
  end
end

SupabaseCli.ProvisionTenant.run()
