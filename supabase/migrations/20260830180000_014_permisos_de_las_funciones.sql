-- Migración 014 — Cerrar los permisos que la 013 dejó abiertos
-- Hito 1 · T5. Encontrado el 30-ago-2026 auditando privilegios antes de arrancar T6.
--
-- La 013 decía en un comentario que `app.firmar_canje` y `app.codigo_canje` "no se otorgan a nadie".
-- Era falso. En Postgres **una función nace con EXECUTE concedido a PUBLIC**, así que revocar solo en
-- `public.create_redemption` y `public.cancel_redemption` no tocó a las otras dos: quedaron
-- ejecutables por `anon` y por `authenticated`.
--
-- POR QUÉ IMPORTA. `app.firmar_canje` es SECURITY DEFINER y lee `merchant_secrets`. Quien pueda
-- llamarla se fabrica un QR firmado válido para CUALQUIER comercio, con el id de canje y el
-- vencimiento que quiera, y lo presenta en un panel sin conexión — que por diseño solo puede
-- verificar la firma (decisión 5). Es exactamente el fraude que el HMAC existe para impedir.
--
-- Hoy no es explotable: PostgREST publica únicamente el esquema `public`, así que un cliente de la
-- app no tiene forma de invocar nada de `app`. Pero "no es alcanzable hoy" no es una defensa, es una
-- casualidad de configuración: alcanza con que alguien agregue `app` a los esquemas expuestos, o que
-- una función de `public` la llame con argumentos que vengan del cliente.
--
-- Lo segundo, menor: `anon` podía ejecutar los dos RPC del canje. No era un agujero —las dos rechazan
-- con `sin_sesion` cuando `auth.uid()` es nulo— pero tampoco tiene por qué poder llamarlas. Viene de
-- los *default privileges* que Supabase deja puestos sobre el esquema `public`, que conceden EXECUTE
-- a `anon`, `authenticated` y `service_role` en cada función nueva. Un `revoke ... from public` no los
-- quita, porque son concesiones explícitas al rol y no al pseudo-rol PUBLIC. Hay que nombrar a `anon`.

-- ---------------------------------------------------------------------------
-- Las funciones internas del esquema `app`: de nadie salvo el dueño
--
-- No hace falta concedérselas a `service_role` ni a nadie: `create_redemption` las llama desde
-- adentro y, siendo SECURITY DEFINER, corre como su dueño. Quien invoca no necesita el permiso.
-- ---------------------------------------------------------------------------

revoke all on function app.firmar_canje(uuid, uuid, timestamptz) from public, anon, authenticated;
revoke all on function app.codigo_canje()                          from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Los RPC del canje: solo con sesión iniciada
-- ---------------------------------------------------------------------------

revoke all on function public.create_redemption(uuid) from anon;
revoke all on function public.cancel_redemption(uuid) from anon;

-- `get_turn_state` y `get_available_benefits` son de lectura, pero también exigen sesión: la primera
-- levanta 28000 sin `auth.uid()` y la segunda depende de ella. Dejarlas abiertas a `anon` solo produce
-- errores confusos en vez de un 401 honesto.
--
-- Hay que nombrar a `public` ADEMÁS de a `anon`. La 009 las creó y les concedió EXECUTE a
-- `authenticated`, pero nunca revocó el permiso que toda función nueva trae para el pseudo-rol PUBLIC,
-- y `anon` lo hereda de ahí. Se reconoce en el ACL: una entrada que empieza con `=X/` —sin nombre de
-- rol a la izquierda— es PUBLIC. Revocar solo a `anon` no cambia nada mientras esa entrada siga.
revoke all on function public.get_turn_state()          from public, anon;
revoke all on function public.get_available_benefits()  from public, anon;

-- Y devolverlas a quien sí las necesita, porque el revoke de arriba se llevó todo por delante.
grant execute on function public.get_turn_state()         to authenticated;
grant execute on function public.get_available_benefits() to authenticated;

-- ---------------------------------------------------------------------------
-- Y se comprueba, porque este es el tipo de cosa que se cree arreglada sin estarlo.
--
-- Es la lección de esta migración: la 013 AFIRMABA en un comentario que los permisos estaban
-- cerrados. Un comentario no cierra nada. Esto sí.
-- ---------------------------------------------------------------------------

do $$
declare
  v_mal text;
begin
  select string_agg(n.nspname || '.' || p.proname || ' → ' || r.rolname, ', ')
    into v_mal
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  cross join (values ('anon'), ('authenticated')) as r(rolname)
  where ((n.nspname = 'app'
          and p.proname in ('firmar_canje', 'codigo_canje', 'refrescar_semilla_demo'))
      or (n.nspname = 'public'
          -- Las CUATRO, no solo las de escritura. La primera versión de esta comprobación miraba
          -- únicamente `create_redemption` y `cancel_redemption`, y por eso dio por buena una
          -- migración que había dejado `get_turn_state` y `get_available_benefits` abiertas a `anon`.
          -- Una verificación que no mira todo lo que la migración toca no verifica nada.
          and p.proname in ('create_redemption', 'cancel_redemption',
                            'get_turn_state', 'get_available_benefits')
          and r.rolname = 'anon'))
    and has_function_privilege(r.rolname, p.oid, 'execute');

  if v_mal is not null then
    raise exception 'Quedaron permisos abiertos: %', v_mal;
  end if;

  -- Y lo que SÍ tiene que seguir funcionando: el usuario logueado reserva y cancela.
  if not has_function_privilege('authenticated', 'public.create_redemption(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.cancel_redemption(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.get_available_benefits()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_turn_state()', 'execute') then
    raise exception 'Se cerró de más: `authenticated` perdió acceso a los RPC del canje.';
  end if;
end $$;
