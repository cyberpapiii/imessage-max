// The MCP conformance suite has no option for request headers, and every
// HTTP request to iMessage Max needs the bearer token. Preload this module
// with `node --import` to add the header to every request the suite sends.
// IMESSAGE_MAX_TOKEN_FILE overrides the default token location.
//
// The suite sends through fetch and undici's request(), which share the
// dispatcher stored under one global symbol, and through node:http.
import { readFileSync } from "node:fs";
import http from "node:http";
import { homedir } from "node:os";
import { join } from "node:path";

const file =
  process.env.IMESSAGE_MAX_TOKEN_FILE ??
  join(homedir(), "Library/Application Support/iMessage Max/token");
const authorization = `Bearer ${readFileSync(file, "utf8").trim()}`;

function withAuthorization(headers) {
  if (headers == null) return { authorization };
  if (Array.isArray(headers)) {
    return Array.isArray(headers[0])
      ? [...headers, ["authorization", authorization]]
      : [...headers, "authorization", authorization];
  }
  if (typeof headers[Symbol.iterator] === "function") {
    return [...headers, ["authorization", authorization]];
  }
  return { ...headers, authorization };
}

// Node creates its global dispatcher the first time fetch runs.
await fetch("data:,");
const key = Symbol.for("undici.globalDispatcher.1");
const agent = globalThis[key];
globalThis[key] = new Proxy(agent, {
  get(target, property) {
    if (property === "dispatch") {
      return (options, handler) =>
        target.dispatch({ ...options, headers: withAuthorization(options.headers) }, handler);
    }
    const value = Reflect.get(target, property, target);
    return typeof value === "function" ? value.bind(target) : value;
  },
});

const request = http.request;
http.request = (options, ...rest) =>
  options !== null && typeof options === "object" && !(options instanceof URL)
    ? request({ ...options, headers: { ...options.headers, authorization } }, ...rest)
    : request(options, ...rest);
