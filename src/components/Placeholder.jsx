// Andamiaje. Cada superficie se reemplaza con el diseño que entregue José.
export default function Placeholder({ surface, note }) {
  return (
    <main className="min-h-dvh bg-neutral-950 text-neutral-100 p-6">
      <h1 className="text-xl font-medium">{surface}</h1>
      <p className="mt-2 text-sm text-neutral-400">{note}</p>
    </main>
  )
}
