-- Migración 004 — updated_at que no miente
-- Hito 1 · revisión de T1 y T2.
--
-- `settings.updated_at` y `benefit_rules.updated_at` se llenaban con el default al insertar y no
-- se volvían a tocar nunca: al primer UPDATE la columna quedaba mintiendo. Una marca de tiempo
-- equivocada es peor que no tenerla, porque se le cree.
--
-- Importa pronto: el panel del comercio (T11) edita cupos y horarios, y el modo offline del Hito 5
-- necesita saber qué reglas cambiaron desde la última sincronización.

create function app.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

comment on function app.touch_updated_at() is
  'Mantiene updated_at en cualquier tabla que tenga esa columna. Se dispara antes del UPDATE, así que gana al valor que mande el cliente.';

create trigger settings_touch_updated_at
  before update on public.settings
  for each row execute function app.touch_updated_at();

create trigger benefit_rules_touch_updated_at
  before update on public.benefit_rules
  for each row execute function app.touch_updated_at();
