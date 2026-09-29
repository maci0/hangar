export type IconProps = {
  readonly name: string;
  readonly class?: string;
};

/** One symbol from the `/icons.svg` sprite (source files live in `assets/icons`). */
export const Icon = ({ name, class: className = "ico" }: IconProps) => (
  <svg class={className} aria-hidden="true">
    <use href={`/icons.svg#i-${name}`} />
  </svg>
);
