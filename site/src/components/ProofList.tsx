import type { ProofItem } from '../content/copy'

type ProofListProps = {
  items: ProofItem[]
  className?: string
}

// Short, labeled receipts for the promise above them. The shared ledger
// creates hierarchy without turning every fact into a card.
export function ProofList({ items, className }: ProofListProps) {
  const classes = className ? `proof-list ${className}` : 'proof-list'

  return (
    <ul className={classes} role="list">
      {items.map((item) => (
        <li className="proof-item" key={item.title}>
          <h3 className="proof-title">{item.title}</h3>
          <p className="proof-body">{item.body}</p>
        </li>
      ))}
    </ul>
  )
}
