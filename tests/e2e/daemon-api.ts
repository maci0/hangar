/** Direct daemon calls made from inside the loaded page, plus the VM-list helpers the specs share. */
import { expect, type Page } from '@playwright/test';

const API_KEY = 'hangar';

/** One entry of `GET /api/vms`; fields other than the name are read through `expect`, which takes any value. */
export type VmRecord = Readonly<Record<string, unknown>> & { readonly name: string };

export type ApiReply = { readonly status: number; readonly ok: boolean; readonly text: string };

/** Sends a request with the API key from the page's own origin. `body` is the raw form or JSON text; omit it for a bodiless request. */
export const api = (page: Page, method: string, path: string, body?: string, headers?: Readonly<Record<string, string>>): Promise<ApiReply> =>
    page.evaluate(
        async (request) => {
            const init: RequestInit = { method: request.method, headers: { 'X-API-Key': request.key, ...request.headers } };
            if (request.body !== null) {
                init.body = request.body;
            }
            const response = await fetch(request.path, init);
            return { status: response.status, ok: response.ok, text: await response.text() };
        },
        { method, path, body: body ?? null, headers: headers ?? {}, key: API_KEY },
    );

/** Decodes JSON text the daemon sent; the caller narrows the result before use. */
export const parseJson = (text: string): unknown => JSON.parse(text);

/** The elements of a JSON array in `text`; anything else reads as an empty list. */
export const parseJsonList = (text: string): Array<unknown> => {
    const body = parseJson(text);
    return typeof body === 'object' && body !== null && 'length' in body ? Object.values(body) : [];
};

export const listVms = async (page: Page): Promise<Array<VmRecord>> => {
    const reply = await api(page, 'GET', '/api/vms');
    expect(reply.ok, `VM list: ${reply.status} ${reply.text}`).toBe(true);
    const entries = parseJsonList(reply.text);
    return entries.filter((entry): entry is VmRecord => typeof entry === 'object' && entry !== null && 'name' in entry && typeof entry.name === 'string');
};

/** How many VMs the daemon lists. */
export const countVms = async (page: Page): Promise<number> => {
    const vms = await listVms(page);
    return vms.length;
};

/** List position of the VM called `name`, or -1. */
export const indexOf = async (page: Page, name: string): Promise<number> => {
    const vms = await listVms(page);
    return vms.findIndex((vm) => vm.name === name);
};

/** The VM called `name`; fails the test when the daemon does not list it. */
export const vmNamed = async (page: Page, name: string): Promise<VmRecord> => {
    const vms = await listVms(page);
    const found = vms.find((vm) => vm.name === name);
    expect(found, `VM ${name} should be listed`).toBeDefined();
    return found ?? { name };
};

/** One field of the VM called `name`, for `expect.poll`. */
export const vmField = async (page: Page, name: string, field: string): Promise<unknown> => {
    const vm = await vmNamed(page, name);
    return vm[field];
};

/** Creates a stopped 1 GB VM and returns its list position. */
export const createVm = async (page: Page, name: string): Promise<number> => {
    const reply = await api(page, 'POST', '/api/vms', `name=${encodeURIComponent(name)}&mem=1024&cpu=1&disk=1`);
    expect(reply.ok, `create ${name}: ${reply.status} ${reply.text}`).toBe(true);
    const index = await indexOf(page, name);
    expect(index, `created VM ${name} should be listed`).toBeGreaterThanOrEqual(0);
    return index;
};

/** Deletes the named VMs when present; the daemon holds 64 VMs at most, so a test removes what it made. */
export const removeVms = async (page: Page, ...names: Array<string>): Promise<void> => {
    for (const name of names) {
        const index = await indexOf(page, name);
        if (index >= 0) {
            await api(page, 'POST', `/api/vms/${index}/delete`, '');
        }
    }
};
