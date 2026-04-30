Deno.serve((req: Request) => {
  const url = new URL(req.url);

  return Response.json({
    ok: true,
    method: req.method,
    path: url.pathname,
  });
});
