import { describe, expect, test } from "bun:test";
import { errorText, messageOf, responseError } from "@/lib/api";

describe("daemon errors", () => {
  test("a JSON body gives its error field", async () => {
    expect(await errorText('{"error":"disk is full"}')).toBe("disk is full");
  });

  test("any other body is the message", async () => {
    expect(await errorText("plain text")).toBe("plain text");
    expect(await errorText('{"error":""}')).toBe('{"error":""}');
    expect(await errorText('{"other":1}')).toBe('{"other":1}');
  });

  test("an empty body falls back to the status", async () => {
    expect(await responseError(new Response("", { status: 502 }))).toBe("HTTP 502");
    expect(await responseError(new Response('{"error":"nope"}', { status: 409 }))).toBe("nope");
  });

  test("messageOf keeps a real message", () => {
    expect(messageOf(new Error("boom"), "x")).toBe("boom");
    expect(messageOf(Object.assign(new Error("gone"), { message: "" }), "x")).toBe("x");
    expect(messageOf("str", "x")).toBe("x");
  });
});
