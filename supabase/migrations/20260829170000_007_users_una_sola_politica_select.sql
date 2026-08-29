-- Migración 007 — Una sola política de lectura en users
-- Hito 1 · T3 (cierre).
--
-- La 005 sumó `users_select_clientes_del_comercio` junto a `users_select_own`, y `public.users`
-- quedó con dos políticas permisivas para el mismo rol y la misma acción. Postgres las evalúa TODAS
-- en cada fila de cada consulta, y el linter de Supabase lo marca.
--
-- La 001 ya había tomado esta decisión —"tres políticas y no un `for all`", para no evaluar dos
-- permisivas en cada lectura— así que esto es volver a esa regla, no inventar una nueva.
--
-- El orden de las condiciones importa: primero la comparación barata contra el uid, después el JWT,
-- y de última la que consulta redemptions, que solo se evalúa si las otras dos no bastaron.

drop policy users_select_clientes_del_comercio on public.users;
drop policy users_select_own on public.users;

create policy users_select on public.users
  for select to authenticated
  using (
    id = (select auth.uid())
    or app.is_platform_admin()
    or app.usuario_canjeo_en(id, app.current_merchant_id())
  );

comment on policy users_select on public.users is
  'Cada usuario se lee a sí mismo; el comercio lee a los clientes que tienen un canje con él; el admin lee todo.';
