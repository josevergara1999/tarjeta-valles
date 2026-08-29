-- Migración 006 — Un canje solo puede gastar giros de su propio dueño
-- Hito 1 · T3 (cierre).
--
-- `redemptions` guarda user_id y entitlement_id por separado, y hasta acá nada impedía escribir una
-- fila donde el canje es de un usuario y el giro se le descuenta a otro. Sería un fallo silencioso
-- y caro: la víctima ve bajar su saldo sin haber canjeado nada.
--
-- Es el mismo cierre que la 005 hizo para benefit/merchant. Que la base lo impida vale más que
-- confiar en que T5 y T6 se acuerden, porque ese es justo el código que todavía no está escrito.

alter table public.entitlements
  add constraint entitlements_id_user_unico unique (id, user_id);

alter table public.redemptions
  add constraint redemptions_entitlement_es_del_usuario
  foreign key (entitlement_id, user_id)
  references public.entitlements (id, user_id) on delete restrict;
