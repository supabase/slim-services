// Exact IEEE-754 values of the Math constants. A defective librusty_v8 build
// froze wrong ones into V8's startup snapshot (supabase/edge-runtime#723).
const MATH_CONSTANTS: Record<string, number> = {
  E: 2.718281828459045,
  LN10: 2.302585092994046,
  LN2: 0.6931471805599453,
  LOG10E: 0.4342944819032518,
  LOG2E: 1.4426950408889634,
  PI: 3.141592653589793,
  SQRT1_2: 0.7071067811865476,
  SQRT2: 1.4142135623730951,
};

// Mismatched constant names with the values the runtime reports; empty when
// every constant is correct.
const math: Record<string, number> = {};
for (const [name, expected] of Object.entries(MATH_CONSTANTS)) {
  const actual = (Math as unknown as Record<string, number>)[name];
  if (actual !== expected) math[name] = actual;
}

Deno.serve((req: Request) => {
  const url = new URL(req.url);

  return Response.json({
    ok: true,
    method: req.method,
    path: url.pathname,
    math,
  });
});
