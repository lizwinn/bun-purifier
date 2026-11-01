// SPDX-License-Identifier: MIT
//
// A registry that accepts one publish, for the checks of publishing. It
// listens on the port in argv[2], writes the body of the first
// `PUT /<package>` to the file in argv[3], answers it like the npm
// registry, and exits. Requests for package metadata get 404, as for a
// package that was never published.

const [port, out] = process.argv.slice(2);

const server = Bun.serve({
  port: Number(port),
  hostname: "127.0.0.1",
  async fetch(request) {
    if (request.method !== "PUT") return new Response("{}", { status: 404 });
    await Bun.write(out, await request.text());
    setTimeout(() => server.stop(), 100);
    return Response.json({ ok: true });
  },
});
