import { Icon } from "@/components/icon";
import { Button } from "@/components/ui/button";

export type LibraryHandlers = {
  readonly newVm: () => void;
  readonly importVm: () => void;
  readonly openCatalog: () => void;
};

/** New VM, Import VM and Catalog: the three ways to add a VM. */
export const LibraryActions = ({ handlers }: { readonly handlers: LibraryHandlers }) => (
  <>
    <Button variant="primary" onClick={handlers.newVm}>
      <Icon name="plus" class="ico size-3.25" />
      New VM
    </Button>
    <Button onClick={handlers.importVm}>
      <Icon name="import" class="ico size-3.25" />
      Import VM
    </Button>
    <Button data-action="openCatalog" onClick={handlers.openCatalog}>
      <Icon name="grid" class="ico size-3.25" />
      Catalog
    </Button>
  </>
);
