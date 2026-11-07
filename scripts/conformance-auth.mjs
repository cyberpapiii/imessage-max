// The MCP conformance suite has no option for request headers, and every
// HTTP request to iMessage Max needs the bearer token. Preload this module
// with `node --import` to add the header to requests the suite sends to the
// server under test, and to no other host. The target is the suite's
// `--url` argument, or IMESSAGE_MAX_URL when the process has none.
// IMESSAGE_MAX_TOKEN_FILE overrides the default token location.
//
// The suite sends through fetch and undici's request(), which share the
// dispatcher stored under one global symbol, and through node:http.
import { readFileSync } from "node:fs";
import http from "node:http";
import { homedir } from "node:os";
import { join } from "node:path";

function targetURL() {
  const args = process.argv;
  for (const [index, arg] of args.entries()) {
    if (arg === "--url" && index + 1 < args.length) return args[index + 1];
    if (arg.startsWith("--url=")) return arg.slice("--url=".length);
  }
  return process.env.IMESSAGE_MAX_URL;
}

const target = targetURL();
if (target === undefined) {
  throw new Error("conformance-auth: pass --url or set IMESSAGE_MAX_URL, so the token goes only to that server");
}
const targetHost = new URL(target).host;

const file =
  process.env.IMESSAGE_MAX_TOKEN_FILE ??
  join(homedir(), "Library/Application Support/iMessage Max/token");
const authorization = `Bearer ${readFileSync(file, "utf8").trim()}`;

function isTarget(url) {
  try {
    return new URL(url).host === targetHost;
  } catch {
    return false;
  }
}

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
  get(dispatcher, property) {
    if (property === "dispatch") {
      return (options, handler) =>
        dispatcher.dispatch(
          isTarget(options.origin) ? { ...options, headers: withAuthorization(options.headers) } : options,
          handler,
        );
    }
    const value = Reflect.get(dispatcher, property, dispatcher);
    return typeof value === "function" ? value.bind(dispatcher) : value;
  },
});

// http.request takes (url[, options][, callback]) or (options[, callback]).
// An options object names its host in parts, so it is rebuilt as a URL.
function optionsURL(options) {
  const hostname = options.hostname ?? options.host ?? "localhost";
  const host = hostname.includes(":") && !hostname.startsWith("[") ? `[${hostname}]` : hostname;
  const protocol = options.protocol ?? "http:";
  return `${protocol}//${host}${options.port == null ? "" : `:${options.port}`}`;
}

const request = http.request;
http.request = (input, ...rest) => {
  if (typeof input === "string" || input instanceof URL) {
    const url = new URL(input);
    if (!isTarget(url)) return request(input, ...rest);
    const options = rest[0] !== null && typeof rest[0] === "object" ? rest.shift() : {};
    return request(url, { ...options, headers: withAuthorization(options.headers) }, ...rest);
  }
  if (input === null || typeof input !== "object" || !isTarget(optionsURL(input))) {
    return request(input, ...rest);
  }
  return request({ ...input, headers: withAuthorization(input.headers) }, ...rest);
};
