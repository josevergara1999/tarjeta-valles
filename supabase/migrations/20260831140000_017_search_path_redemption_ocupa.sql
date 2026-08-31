-- Migración 017 — `app.redemption_ocupa` con search_path fijo
-- Hito 1. Lo encontró el Security Advisor de Supabase (splinter), no yo.
--
-- Todas las funciones del proyecto fijan `search_path`; esta se quedó sin fijarlo. Mi auditoría de
-- privilegios no la vio porque filtraba por `prosecdef`, y esta función NO es SECURITY DEFINER: es
-- una expresión pura sobre un enum y un timestamp. El linter de Supabase, que mira todas las
-- funciones sin importar eso, la marcó al primer intento.
--
-- Vale la pena anotar por qué el filtro estaba mal. Un `search_path` mutable es peligroso sobre todo
-- en SECURITY DEFINER, porque ahí la función corre con los permisos del dueño y quien llama controla
-- dónde se resuelven los nombres. Pero "sobre todo" no es "solamente": una función normal con
-- search_path mutable también resuelve sus nombres contra el camino de quien la invoca, y si mañana
-- alguien le agrega una referencia a una tabla, hereda el problema sin que nadie lo note.
--
-- El riesgo concreto hoy es nulo —`redemption_ocupa` solo compara un enum y llama a `now()`, que vive
-- en `pg_catalog` y siempre se resuelve primero— así que esto no arregla un agujero: alinea la última
-- función que quedaba fuera de la convención, para que "todas las funciones fijan search_path" sea
-- una afirmación verdadera y no casi verdadera. Una excepción sin explicación es una invitación a la
-- siguiente.
--
-- LECCIÓN, y es la tercera vez en dos días que aparece la misma: **la comprobación propia hereda los
-- puntos ciegos de quien la escribe.** Yo busqué exactamente lo que creía que podía fallar. Conviene
-- pasar además una herramienta ajena — acá, el Security Advisor del panel — porque busca lo que a uno
-- no se le ocurrió.

create or replace function app.redemption_ocupa(
  p_estado    public.redemption_estado,
  p_expira_at timestamptz
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_estado = 'validado'
      or (p_estado = 'pendiente' and p_expira_at > now());
$$;

comment on function app.redemption_ocupa(public.redemption_estado, timestamptz) is
  'Si un canje ocupa cupo: validado, o pendiente todavía vigente. Lista blanca a propósito — un estado nuevo del enum no ocupa hasta que alguien lo agregue acá, que es el lado seguro del error.';

-- `stable` y no `immutable` se mantiene: lee `now()`, y marcarla immutable dejaría que el
-- planificador la evaluara una sola vez, con lo que un pendiente que expira a mitad de la consulta
-- seguiría contando como ocupado.

do $$
declare v_sin_path text;
begin
  select string_agg(n.nspname || '.' || p.proname, ', ' order by p.proname)
    into v_sin_path
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public','app')
    and p.prokind = 'f'
    and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search\_path=%');

  if v_sin_path is not null then
    raise exception 'Todavía hay funciones sin search_path fijo: %', v_sin_path;
  end if;
end $$;
