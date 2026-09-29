import { Icon } from "@/components/icon";
import { Button } from "@/components/ui/button";

/** New VM, Import VM and Catalog: the three ways to add a VM. Handlers are the delegated `data-action`s. */
export const LibraryActions = () => (
  <>
    <Button variant="primary" data-action="newVm">
      <Icon name="plus" class="ico size-3.25" />
      New VM
    </Button>
    <Button data-action="importGuest">
      <Icon name="import" class="ico size-3.25" />
      Import VM
    </Button>
    <Button data-action="openCatalog">
      <Icon name="grid" class="ico size-3.25" />
      Catalog
    </Button>
  </>
);
