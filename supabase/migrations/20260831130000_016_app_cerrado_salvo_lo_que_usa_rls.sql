-- Migración 016 — Reabrir lo que RLS necesita, dejar cerrado el resto
-- Hito 1. Corrige la 015, que cerró de más. Referencia: regla dura 1.
--
-- LA 015 ROMPIÓ LA BASE Y ESTA MIGRACIÓN LA ARREGLA. Conviene dejar escrito por qué, porque el
-- razonamiento que la llevó al error es de los que se repiten.
--
-- La 015 revocó USAGE sobre el esquema `app` y EXECUTE sobre todas sus funciones, con el argumento de
-- que son piezas internas llamadas siempre desde funciones SECURITY DEFINER de `public`, y que dentro
-- de una SECURITY DEFINER los permisos se comprueban contra el dueño. Eso es cierto.
--
-- Lo que no es cierto es que TODAS las llamadas vengan de ahí. **Las expresiones de las políticas RLS
-- se evalúan con los privilegios de quien consulta**, no con los del dueño de la tabla. Y seis
-- políticas de este esquema llaman a funciones de `app`. Al cerrarlas, un simple
--
--     select count(*) from public.merchants
--
-- hecho por un usuario normal devolvía `42501: permission denied for function current_merchant_id`.
-- No es que se viera menos: es que la aplicación entera dejaba de leer.
--
-- Lo atraparon las pruebas al primer intento, antes de que llegara a ninguna parte. Es exactamente el
-- caso que justifica tenerlas: la 015 pasó su propia verificación —comprobaba permisos, y los
-- permisos habían quedado como ella quería— pero no comprobaba que el producto siguiera funcionando.
-- Una verificación que solo mira lo que la migración quiso hacer no detecta lo que rompió.

-- ---------------------------------------------------------------------------
-- Lo que RLS necesita y por eso vuelve a abrirse
--
-- Para poder evaluar una política que llama a `app.loquesea()`, quien consulta necesita dos cosas:
-- USAGE sobre el esquema y EXECUTE sobre esa función. Se conceden solo estas, una por una, y no con
-- un `grant on all functions` — la lista corta es la documentación de qué expone RLS hacia afuera.
-- ---------------------------------------------------------------------------

grant usage on schema app to anon, authenticated;

grant execute on function app.current_merchant_id()                     to anon, authenticated;
grant execute on function app.is_platform_admin()                       to anon, authenticated;
grant execute on function app.merchant_activo(uuid)                     to anon, authenticated;
grant execute on function app.benefit_merchant_id(uuid)                 to anon, authenticated;
grant execute on function app.benefit_publico(uuid)                     to anon, authenticated;
grant execute on function app.usuario_canjeo_en(uuid, uuid)             to anon, authenticated;

-- `dias_semana_validos` no la usa una política sino un CHECK de `benefit_rules`, que se evalúa al
-- escribir y por lo tanto también con los privilegios de quien escribe.
grant execute on function app.dias_semana_validos(smallint[])           to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Lo que queda cerrado, que es el objetivo real de todo esto
--
-- Todo lo demás de `app` sigue revocado por la 015. Importan sobre todo estas, que son SECURITY
-- DEFINER, reciben un `user_id` arbitrario y no comprueban que sea el de quien llama —no tienen por
-- qué: las invoca siempre una función de `public` que ya resolvió la identidad—:
--
--   app.giros_disponibles(uuid)                  el saldo de cualquier usuario
--   app.canjes_del_dia(uuid, date)               su actividad del día
--   app.franja_gastada(uuid, franja_dia, date)   si ya gastó su franja
--   app.firmar_canje(uuid, uuid, timestamptz)    un QR firmado para cualquier comercio
--
-- `usuario_canjeo_en` es del mismo tipo y sí queda abierta, porque una política la necesita. Es un
-- booleano —"¿este usuario canjeó alguna vez en este local?"— y es justamente lo que RLS usa para
-- dejar que un comercio vea a sus propios clientes. Se acepta a conciencia.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Verificación: primero que lo cerrado esté cerrado, y DESPUÉS que la app funcione.
--
-- Lo segundo es lo que le faltó a la 015.
-- ---------------------------------------------------------------------------

do $$
declare
  v_abiertas text;
  v_n        integer;
begin
  select string_agg(p.proname, ', ' order by p.proname)
    into v_abiertas
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app'
    and p.proname in ('giros_disponibles','canjes_del_dia','franja_gastada',
                      'firmar_canje','codigo_canje','refrescar_semilla_demo',
                      'franja_en','dia_operativo','semana_operativa','hora_local',
                      'proxima_franja_at','redemption_ocupa',
                      'setting_text','setting_int','setting_numeric')
    and (has_function_privilege('anon', p.oid, 'execute')
      or has_function_privilege('authenticated', p.oid, 'execute'));

  if v_abiertas is not null then
    raise exception 'Estas funciones internas siguen abiertas a la API: %', v_abiertas;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- La prueba de fuego —que un usuario normal pueda leer la red— NO va acá.
--
-- El primer intento de esta migración la hacía con `set local role authenticated` … `reset role`, y
-- el `reset role` reventó el push: el CLI de Supabase entra con un rol temporal y hace su propio
-- `set role` para escribir en `supabase_migrations`, así que resetear el rol le sacó a la herramienta
-- el permiso de anotar la migración. **Una migración no debe cambiar de rol.**
--
-- Tampoco hace falta. `supabase/tests/001_rls.sql` ya comprueba, con el token de un usuario final,
-- que vea la red de comercios activa — y es la comprobación que atrapó el error de la 015 al primer
-- intento. El lugar de una prueba funcional es la batería de pruebas, no una migración.
-- ---------------------------------------------------------------------------
