import type { ReactNode } from "react";
import * as Dialog from "@radix-ui/react-dialog";
import * as Menu from "@radix-ui/react-dropdown-menu";
import { X } from "./icons";
export function Modal({
  open,
  onOpenChange,
  title,
  description,
  children,
  wide = false,
}: {
  open: boolean;
  onOpenChange: (v: boolean) => void;
  title: string;
  description?: string;
  children: ReactNode;
  wide?: boolean;
}) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="modal-overlay" />
        <Dialog.Content className={`modal ${wide ? "modal-wide" : ""}`}>
          <Dialog.Title className="modal-title">{title}</Dialog.Title>
          <Dialog.Description
            className={description ? "modal-description" : "sr-only"}
          >
            {description || title}
          </Dialog.Description>
          <Dialog.Close className="icon-button modal-close" aria-label="Close">
            <X size={20} />
          </Dialog.Close>
          {children}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
export function DropMenu({
  children,
  items,
}: {
  children: ReactNode;
  items: {
    label: string;
    icon?: ReactNode;
    action: () => void;
    danger?: boolean;
  }[];
}) {
  return (
    <Menu.Root>
      <Menu.Trigger asChild>{children}</Menu.Trigger>
      <Menu.Portal>
        <Menu.Content className="dropdown" sideOffset={6} align="end">
          {items.map((item, i) => (
            <Menu.Item
              key={i}
              className={`dropdown-item ${item.danger ? "danger" : ""}`}
              onSelect={item.action}
            >
              {item.icon}
              {item.label}
            </Menu.Item>
          ))}
        </Menu.Content>
      </Menu.Portal>
    </Menu.Root>
  );
}
