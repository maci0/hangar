import { useEffect, useRef, useState, type MutableRef } from "preact/hooks";
import { Icon } from "@/components/icon";
import { Button } from "@/components/ui/button";
import { Dialog, DialogBody, DialogClose, DialogFooter, DialogTitle, useDialogTask } from "@/components/ui/dialog";
import { Field, focusFirstInvalid, InputField } from "@/components/ui/field";
import { Select } from "@/components/ui/select";
import { cn } from "@/lib/cn";
import { NET_BORDER, NET_DOT, netKindOf, netTypeLabel } from "@/lib/network";
import { cleanVnet, firstInvalid, VNET_MAX, validateVnet, type Vnet } from "@/lib/vnet";

export type VnetsRequest = {
  readonly networks: ReadonlyArray<Vnet>;
  /** Network to show first; a newer object selects again, even for the same name. */
  readonly select?: { readonly name: string };
  /** Writes the whole set; `saved` names the selected network for Save Selected, null for Save All. Resolves whether it was written. */
  readonly save: (networks: ReadonlyArray<Vnet>, saved: string | null) => Promise<boolean>;
  /** Asks whether unsaved edits may be thrown away. */
  readonly confirmDiscard: () => Promise<boolean>;
  /** Opens Network Topology over the editor. */
  readonly openTopology: () => void;
};

/** Networks restored by Defaults: the three VMware-style switches. */
const DEFAULT_NETWORKS: ReadonlyArray<Vnet> = [
  { name: "VMnet0", type: "bridged", subnet: "", mask: "", dhcp: false, dhcp_start: "", dhcp_end: "", host_iface: "auto", gateway: "", port_forwards: "" },
  {
    name: "VMnet1",
    type: "host_only",
    subnet: "192.168.118.0",
    mask: "255.255.255.0",
    dhcp: true,
    dhcp_start: "192.168.118.128",
    dhcp_end: "192.168.118.254",
    host_iface: "",
    gateway: "",
    port_forwards: "",
  },
  {
    name: "VMnet8",
    type: "nat",
    subnet: "192.168.140.0",
    mask: "255.255.255.0",
    dhcp: true,
    dhcp_start: "192.168.140.128",
    dhcp_end: "192.168.140.254",
    host_iface: "",
    gateway: "192.168.140.2",
    port_forwards: "2222:192.168.140.128:22",
  },
];

const NEW_NETWORK: Vnet = {
  name: "",
  type: "host_only",
  subnet: "192.168.100.0",
  mask: "255.255.255.0",
  dhcp: true,
  dhcp_start: "192.168.100.128",
  dhcp_end: "192.168.100.254",
  host_iface: "",
  gateway: "",
  port_forwards: "",
};

const newNetwork = (existing: ReadonlyArray<Vnet>): Vnet => {
  const used = new Set(existing.map((net) => net.name));
  let number = existing.length;
  while (used.has(`VMnet${number}`)) {
    number += 1;
  }
  return { ...NEW_NETWORK, name: `VMnet${number}` };
};

const NONE = -1;

const indexOfName = (nets: ReadonlyArray<Vnet>, name: string | undefined): number => {
  const found = nets.findIndex((net) => net.name === name);
  if (found !== NONE) {
    return found;
  }
  return nets.length > 0 ? 0 : NONE;
};

type NetworkListProps = {
  readonly networks: ReadonlyArray<Vnet>;
  readonly selected: number;
  readonly onSelect: (index: number) => void;
};

/** Index the option keys move to from `selected` among `count` options; null for any other key. */
const optionTarget = (key: string, selected: number, count: number): number | null => {
  switch (key) {
    case "ArrowUp": {
      return Math.max(0, selected - 1);
    }
    case "ArrowDown": {
      return Math.min(count - 1, selected + 1);
    }
    case "Home": {
      return 0;
    }
    case "End": {
      return count - 1;
    }
    default: {
      return null;
    }
  }
};

const NetworkList = ({ networks, selected, onSelect }: NetworkListProps) => {
  const list = useRef<HTMLDivElement>(null);

  const onKeyDown = (event: KeyboardEvent) => {
    const target = optionTarget(event.key, selected, networks.length);
    if (target !== null) {
      event.preventDefault();
      onSelect(target);
      list.current?.querySelectorAll<HTMLElement>("[role=option]")[target]?.focus();
    }
  };

  if (networks.length === 0) {
    return <p class="px-3 py-4 text-center text-xs text-fg-dim">No virtual networks. Add one below.</p>;
  }
  return (
    <div
      id="vnet_sel"
      ref={list}
      role="listbox"
      aria-label="Network list"
      class="flex max-h-70 flex-col gap-1.5 overflow-y-auto p-0.5"
      onKeyDown={onKeyDown}
    >
      {networks.map((net, index) => {
        const kind = netKindOf(net.type);
        const on = index === selected;
        return (
          <button
            key={index}
            type="button"
            role="option"
            aria-selected={on}
            tabIndex={on ? 0 : -1}
            autofocus={on}
            data-vnet-type={net.type.toLowerCase()}
            class={cn(
              "vnet-item flex w-full items-center gap-2.5 rounded-sm border border-border bg-surface px-2.75 py-2.25 text-left text-fg transition-colors hover:border-accent focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent pointer-coarse:min-h-11",
              on && "active border-accent bg-accent-soft",
            )}
            onClick={() => onSelect(index)}
          >
            <span aria-hidden="true" class={cn("size-2.5 flex-none rounded-full", NET_DOT[kind])} />
            <span class="mr-auto min-w-0 truncate text-field font-semibold">{net.name}</span>
            <span
              data-net-type={net.type.toLowerCase()}
              class={cn(
                "vnet-type-badge rounded-sm border px-1.5 py-px text-caption font-bold tracking-wide whitespace-nowrap text-fg-muted uppercase",
                NET_BORDER[kind],
              )}
            >
              {netTypeLabel(net.type)}
            </span>
          </button>
        );
      })}
    </div>
  );
};

type ValueEvent = { readonly currentTarget: { readonly value: string } };

type NetworkFormProps = {
  readonly net: Vnet;
  readonly showErrors: boolean;
  readonly onChange: (patch: Partial<Vnet>) => void;
};

const PAIR = "grid grid-cols-2 items-start gap-3 max-phone:grid-cols-1";

const NetworkForm = ({ net, showErrors, onChange }: NetworkFormProps) => {
  const errors = showErrors ? validateVnet(net) : {};
  const text = (key: "name" | "subnet" | "mask" | "dhcp_start" | "dhcp_end" | "host_iface" | "gateway" | "port_forwards") => ({
    value: net[key],
    onInput: (event: ValueEvent) => onChange({ [key]: event.currentTarget.value }),
  });
  return (
    <div class="grid content-start gap-3">
      <InputField id="vn_name" label="Name" type="text" error={errors.name} {...text("name")} />
      <div class={PAIR}>
        <Field label="Type" htmlFor="vn_type">
          <Select id="vn_type" value={net.type} onChange={(event) => onChange({ type: event.currentTarget.value })}>
            <option value="nat">NAT</option>
            <option value="bridged">Bridged</option>
            <option value="host_only">Host-Only</option>
          </Select>
        </Field>
        <Field label="DHCP" htmlFor="vn_dhcp">
          <Select id="vn_dhcp" value={net.dhcp ? "1" : "0"} onChange={(event) => onChange({ dhcp: event.currentTarget.value === "1" })}>
            <option value="0">Off</option>
            <option value="1">On</option>
          </Select>
        </Field>
      </div>
      <div class={PAIR}>
        <InputField id="vn_subnet" label="Subnet" type="text" placeholder="192.168.1.0" error={errors.subnet} {...text("subnet")} />
        <InputField id="vn_mask" label="Netmask" type="text" placeholder="255.255.255.0" error={errors.mask} {...text("mask")} />
      </div>
      <div class={PAIR}>
        <InputField id="vn_dstart" label="DHCP Start" type="text" placeholder="192.168.1.100" error={errors.dhcp_start} {...text("dhcp_start")} />
        <InputField id="vn_dend" label="DHCP End" type="text" placeholder="192.168.1.200" error={errors.dhcp_end} {...text("dhcp_end")} />
      </div>
      <div class={PAIR}>
        <InputField id="vn_iface" label="Host Interface" type="text" {...text("host_iface")} />
        <InputField id="vn_gw" label="Gateway" type="text" error={errors.gateway} {...text("gateway")} />
      </div>
      <InputField id="vn_pf" label="Port Forwards" type="text" placeholder="host:guest,..." {...text("port_forwards")} />
    </div>
  );
};

type Editor = {
  readonly networks: ReadonlyArray<Vnet>;
  readonly selected: number;
  readonly select: (index: number) => void;
  readonly showErrors: boolean;
  readonly update: (patch: Partial<Vnet>) => void;
  readonly add: () => void;
  readonly remove: () => void;
  readonly restoreDefaults: () => void;
  /** Validates every network, then writes the set; resolves whether it was written. */
  readonly persist: (saved: string | null) => Promise<boolean>;
};

/** Edit state of the dialog: the working copy of the networks and the selected index. */
const useVnetEditor = (request: VnetsRequest, dirty: MutableRef<boolean>): Editor => {
  const [networks, setNetworks] = useState<ReadonlyArray<Vnet>>(request.networks);
  const [selected, setSelected] = useState(() => indexOfName(request.networks, request.select?.name));
  const [showErrors, setShowErrors] = useState(false);

  const latest = useRef(networks);
  latest.current = networks;
  useEffect(() => {
    if (request.select !== undefined) {
      setSelected(indexOfName(latest.current, request.select.name));
    }
  }, [request.select]);

  const edit = (next: ReadonlyArray<Vnet>, index: number) => {
    setNetworks(next);
    setSelected(index);
    dirty.current = true;
  };

  const persist = async (saved: string | null): Promise<boolean> => {
    const bad = firstInvalid(networks);
    if (bad !== NONE) {
      setShowErrors(true);
      setSelected(bad);
      focusFirstInvalid("vnetdlg");
      return false;
    }
    const cleaned = networks.map((net) => cleanVnet(net));
    if (!(await request.save(cleaned, saved))) {
      return false;
    }
    setNetworks(cleaned);
    dirty.current = false;
    return true;
  };

  return {
    networks,
    selected,
    select: setSelected,
    showErrors,
    update: (patch) => {
      edit(
        networks.map((net, index) => (index === selected ? { ...net, ...patch } : net)),
        selected,
      );
    },
    add: () => edit([...networks, newNetwork(networks)], networks.length),
    remove: () =>
      edit(
        networks.filter((_, index) => index !== selected),
        Math.min(selected, networks.length - 2),
      ),
    restoreDefaults: () => edit(DEFAULT_NETWORKS, 0),
    persist,
  };
};

type FooterProps = {
  readonly count: number;
  readonly hasSelection: boolean;
  readonly busy: boolean;
  readonly editor: Editor;
  readonly run: (task: () => Promise<boolean>) => void;
  readonly openTopology: () => void;
};

const VnetsFooter = ({ count, hasSelection, busy, editor, run, openTopology }: FooterProps) => {
  const { networks, selected, persist } = editor;
  return (
    <DialogFooter>
      <div class="mr-auto flex flex-wrap gap-2">
        <Button type="button" data-action="vnetAdd" disabled={count >= VNET_MAX} onClick={editor.add}>
          <Icon name="plus" />
          Add
        </Button>
        <Button type="button" variant="danger" data-action="vnetRemove" disabled={!hasSelection} onClick={editor.remove}>
          <Icon name="trash" />
          Remove
        </Button>
        <Button type="button" data-action="vnetDefaults" onClick={editor.restoreDefaults}>
          Defaults
        </Button>
        <Button type="button" data-action="openTopology" onClick={openTopology} title="Visual network topology">
          <Icon name="net" />
          Topology
        </Button>
      </div>
      <Button
        type="button"
        data-action="vnetSaveCurrent"
        disabled={busy || !hasSelection}
        onClick={() =>
          run(async () => {
            await persist(networks[selected]?.name.trim() ?? null);
            return false;
          })
        }
      >
        Save Selected
      </Button>
      <Button type="button" variant="primary" data-action="vnetSaveAll" disabled={busy} onClick={() => run(() => persist(null))}>
        Save All
      </Button>
      <DialogClose>Close</DialogClose>
    </DialogFooter>
  );
};

const VnetsEditor = ({ request, dirty }: { readonly request: VnetsRequest; readonly dirty: MutableRef<boolean> }) => {
  const { busy, run } = useDialogTask();
  const editor = useVnetEditor(request, dirty);
  const { networks, selected } = editor;
  const current = networks[selected];

  return (
    <>
      <DialogBody class="grid grid-cols-3 gap-4 max-phone:grid-cols-1">
        <div>
          <NetworkList networks={networks} selected={selected} onSelect={editor.select} />
          {networks.length >= VNET_MAX && <p class="mt-2 text-caption text-fg-dim">The limit of {VNET_MAX} virtual networks is reached.</p>}
        </div>
        <div class="col-span-2 max-phone:col-span-1">
          {current === undefined ? (
            <p class="text-xs text-fg-dim">Select or add a network to edit it.</p>
          ) : (
            <NetworkForm net={current} showErrors={editor.showErrors} onChange={editor.update} />
          )}
        </div>
      </DialogBody>
      <VnetsFooter count={networks.length} hasSelection={current !== undefined} busy={busy} editor={editor} run={run} openTopology={request.openTopology} />
    </>
  );
};

export type VnetsDialogProps = {
  readonly request: VnetsRequest;
  readonly onClose: () => void;
};

/** Virtual Network Editor. Edits stay in the dialog until saved; closing with unsaved edits asks first. */
export const VnetsDialog = ({ request, onClose }: VnetsDialogProps) => {
  const dirty = useRef(false);
  return (
    <Dialog
      id="vnetdlg"
      titleId="vnet-title"
      class="w-170"
      onClose={onClose}
      guard={() => !dirty.current || request.confirmDiscard()}
    >
      <DialogTitle id="vnet-title">Virtual Network Editor</DialogTitle>
      <VnetsEditor request={request} dirty={dirty} />
    </Dialog>
  );
};
