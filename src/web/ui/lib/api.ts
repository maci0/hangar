/**
 * Daemon calls. The bundled UI is same-origin and only fully functional under the daemon's built-in
 * key (loopback). Setting `KV_API_KEY` to a strong secret exposes the daemon on all interfaces for
 * vmrun and remote use, and browser write actions then return 401: that path is CLI-only.
 */
export const API_KEY = "hangar";

/** Header set of the calls that carry the key. */
export const AUTH_HEADERS: Readonly<Record<string, string>> = { "X-API-Key": API_KEY };

/** The message in a daemon error body: the `error` field of a JSON body, else the body itself. */
export const errorText = async (body: string): Promise<string> => {
  const parsed: unknown = await new Response(body).json().catch((): undefined => undefined);
  return typeof parsed === "object" && parsed !== null && "error" in parsed && typeof parsed.error === "string" && parsed.error !== "" ? parsed.error : body;
};

/** What went wrong with a non-2xx response: the daemon's message, or `HTTP <status>` when it sent none. */
export const responseError = async (response: Response): Promise<string> => {
  const body = await response.text().catch(() => "");
  return (await errorText(body)) || `HTTP ${response.status}`;
};

/** Message of a caught value. */
export const messageOf = (error: unknown, fallback: string): string => (error instanceof Error && error.message !== "" ? error.message : fallback);
