import { setLoadBar, setStatus, setStatusLoading, showToast } from "@/app/feedback";
import { state } from "@/app/state";
import { AUTH_HEADERS, messageOf, responseError } from "@/lib/api";

/**
 * Longest a write may hold the gate. Set well above realistic operations (compacting or resizing a
 * large qcow2 image can take minutes) so a slow but progressing write keeps the gate for its whole
 * duration; `apiPost` itself releases it when the request ends.
 */
const POST_GATE_TIMEOUT_MS = 300_000;

/** Takes the write gate; false while another write holds it. */
const takeGate = (): boolean => {
  if (state.postBusy) {
    return false;
  }
  state.postBusy = true;
  state.postGeneration += 1;
  const generation = state.postGeneration;
  setTimeout(() => {
    if (state.postGeneration === generation) {
      state.postBusy = false;
      state.postPending = 0;
      setLoadBar(false);
      setStatus("");
    }
  }, POST_GATE_TIMEOUT_MS);
  return true;
};

const releaseGate = (): void => {
  state.postBusy = false;
  state.postGeneration += 1;
};

/** Whether a write is running: the poll stands still meanwhile. */
export const writeInFlight = (): boolean => state.postBusy || state.postPending > 0;

/** Sends the write; throws with the daemon's message when it answers with an error status. */
const send = async (url: string, body: string): Promise<Response> => {
  const response = await fetch(url, { method: "POST", body, headers: AUTH_HEADERS });
  if (!response.ok) {
    throw new Error(await responseError(response));
  }
  return response;
};

/**
 * POSTs a form body (or JSON for `/api/networks`) with the API key. One write runs at a time: a second is
 * refused with a toast. Resolves the response, or null after reporting the failure (status bar and toast).
 */
export const apiPost = async (url: string, body = ""): Promise<Response | null> => {
  if (!takeGate()) {
    showToast("Another operation is in progress, please wait.", "warn");
    return null;
  }
  const previous = state.statusText;
  if (state.postPending <= 0) {
    setStatusLoading("Working...");
    setLoadBar(true);
  }
  state.postPending += 1;
  const outcome = await send(url, body).then(
    (response) => ({ response, failure: null }),
    (error: unknown) => ({ response: null, failure: messageOf(error, "Request failed") }),
  );
  state.postPending -= 1;
  if (outcome.failure === null) {
    if (state.postPending <= 0) {
      setStatus(previous);
      setLoadBar(false);
    }
  } else {
    if (state.postPending <= 0) {
      setStatus(`Error: ${outcome.failure}`);
      setLoadBar(false);
    }
    showToast(outcome.failure, "error");
  }
  releaseGate();
  return outcome.response;
};
