-- Migración 013 — `create_redemption` y `cancel_redemption`
-- Hito 1 · T5. Referencias: docs/decisiones-hito-1.md (1, 2, 5, 12), spec 3.2, regla dura 3.
--
-- Acá se RESERVA el giro. No se descuenta: eso pasa cuando el comercio valida, en T6. La 009 dice lo
-- que se PUEDE mostrar; esta migración dice lo que se COMPROMETE, y entre una lectura y la otra el
-- mundo cambia — por eso todo se vuelve a evaluar acá adentro, con lock.
--
-- ---------------------------------------------------------------------------
-- Cómo se informan los errores
--
-- Todos los rechazos de negocio salen con `errcode = 'P0001'`, que es lo que PostgREST traduce a un
-- HTTP 400. Un SQLSTATE inventado (`TV001` y parecidos) se vería más elegante, pero PostgREST manda
-- 500 ante un código que no conoce, y un "sin giros" no es un error del servidor.
--
-- El motivo legible por máquina va en DETAIL, que PostgREST devuelve en el cuerpo como `details`. El
-- MESSAGE es el texto para una persona. La pantalla decide con `details`, nunca parseando el mensaje:
--
--   sin_sesion · beneficio_inexistente · beneficio_no_disponible · sin_giros · canje_pendiente
--   franja_gastada · techo_diario · sin_entitlement · codigo_no_generado
--   canje_inexistente (al cancelar) · canje_no_pendiente (al cancelar)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- El formato del código firmado del QR
--
-- La decisión 5 fijó el CONTENIDO —redemption_id, merchant_id, expira_at y un HMAC con el secreto del
-- comercio— pero no el encoding. Se define acá porque T10 lo va a tener que parsear sin conexión:
--
--   v1.<redemption_id>.<merchant_id>.<expira_at en segundos epoch>.<hmac_sha256 en hex>
--
-- Separado por puntos porque ni un uuid ni un número los contienen, así que partir por '.' es
-- inequívoco. La versión al frente para poder cambiar el formato sin romper los paneles viejos: un
-- panel que lea `v2.` y no lo entienda puede pedir conexión en vez de rechazar al cliente.
--
-- Se firma la cadena SIN la firma, es decir los cuatro primeros campos con sus puntos. El panel
-- rearma esa cadena, la firma con su propio secreto y compara.
--
-- Recordar la salvedad de la decisión 5: **el HMAC prueba autenticidad, no unicidad.** Sin conexión
-- nadie puede saber si ese código ya se usó. Eso se mitiga en el Hito 5 con caché local y tope de
-- canjes sin sincronizar, no acá.
-- ---------------------------------------------------------------------------

create or replace function app.firmar_canje(
  p_redemption_id uuid,
  p_merchant_id   uuid,
  p_expira_at     timestamptz
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_payload text;
  v_secreto text;
begin
  v_payload := 'v1.' || p_redemption_id::text
                     || '.' || p_merchant_id::text
                     || '.' || extract(epoch from p_expira_at)::bigint::text;

  select s.hmac_secret into v_secreto
  from public.merchant_secrets s
  where s.merchant_id = p_merchant_id;

  if v_secreto is null then
    -- La 001 crea el secreto por trigger con cada comercio, así que esto no debería pasar nunca. Si
    -- pasa, es preferible caerse que emitir un QR sin firma que el panel aceptaría como válido.
    raise exception 'El comercio % no tiene secreto HMAC', p_merchant_id
      using errcode = 'P0001', detail = 'comercio_sin_secreto';
  end if;

  return v_payload || '.' || encode(
    extensions.hmac(v_payload, v_secreto, 'sha256'), 'hex'
  );
end;
$$;

comment on function app.firmar_canje(uuid, uuid, timestamptz) is
  'Arma el payload del QR y lo firma con el secreto del comercio. Formato v1.<redemption>.<merchant>.<epoch>.<hmac>. Vive en el esquema app: nunca se publica por la API, porque leer secretos no es algo que un cliente deba poder pedir.';

-- ---------------------------------------------------------------------------
-- Un código de 6 dígitos que no se pueda adivinar
--
-- `random()` no sirve: es un PRNG sembrado, y con un puñado de códigos observados se puede predecir
-- el siguiente. El código vive 5 minutos y lo protege el índice único, pero adivinarlo permitiría a
-- un tercero quemarle el canje a otro, así que se saca de `gen_random_bytes`.
--
-- El módulo introduce un sesgo mínimo (2^32 no es múltiplo de 10^6): unos valores salen una vez más
-- cada 4295 sorteos. Para un código efímero de 6 dígitos es irrelevante.
-- ---------------------------------------------------------------------------

create or replace function app.codigo_canje()
returns text
language sql
volatile
set search_path = ''
as $$
  select lpad(((
      get_byte(b, 0)::bigint * 16777216
    + get_byte(b, 1)::bigint * 65536
    + get_byte(b, 2)::bigint * 256
    + get_byte(b, 3)::bigint
  ) % 1000000)::text, 6, '0')
  from (select extensions.gen_random_bytes(4) as b) s;
$$;

-- ---------------------------------------------------------------------------
-- `create_redemption` — la reserva
-- ---------------------------------------------------------------------------

create or replace function public.create_redemption(p_benefit_id uuid)
returns table (
  redemption_id uuid,
  codigo        text,
  expira_at     timestamptz,
  qr_payload    text
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user     uuid := (select auth.uid());
  v_ahora    timestamptz := now();
  v_merchant uuid;
  v_estado   record;
  v_ent      uuid;
  v_ttl      integer;
  v_expira   timestamptz;
  v_codigo   text;
  v_id       uuid;
  v_intento  integer;
begin
  if v_user is null then
    raise exception 'Hay que iniciar sesión para canjear'
      using errcode = 'P0001', detail = 'sin_sesion';
  end if;

  -- 1. Barrer los pendientes vencidos del usuario.
  --
  -- Obligatorio y va PRIMERO. El índice `redemptions_un_pendiente_por_usuario` es más estricto que la
  -- decisión 2: bloquea con cualquier fila en estado 'pendiente', incluso una que venció hace horas y
  -- que nadie marcó. Sin este barrido, un usuario que dejó expirar un canje no puede volver a
  -- reservar nunca más. Quedó anotado al cerrar T3 y es la trampa más fácil de pisar de toda la tarea.
  --
  -- El alias `r` no es decorativo: `expira_at` y `codigo` son a la vez columnas de esta tabla y
  -- parámetros de salida de esta función, y sin calificar Postgres corta con "column reference
  -- expira_at is ambiguous". Cualquier sentencia de acá que toque esas dos columnas va aliasada.
  update public.redemptions as r
     set estado = 'expirado'
   where r.user_id = v_user
     and r.estado = 'pendiente'
     and r.expira_at <= v_ahora;

  -- 2. Lock sobre el beneficio.
  --
  -- Es la decisión 1. Dos usuarios pidiendo la última casilla del día pasarían los dos un chequeo
  -- previo y se insertarían los dos. Tomando la fila del beneficio con FOR UPDATE, el segundo espera
  -- al primero y recién entonces evalúa los cupos, ya con el canje del otro escrito.
  --
  -- Alcanza con esta fila porque TODA reserva pasa por esta función: no hay otra puerta que escriba
  -- en `redemptions` en estado pendiente.
  select b.merchant_id into v_merchant
  from public.benefits b
  where b.id = p_benefit_id
  for update;

  if v_merchant is null then
    raise exception 'Ese beneficio no existe'
      using errcode = 'P0001', detail = 'beneficio_inexistente';
  end if;

  -- 3. Las dos puertas del usuario: saldo y ritmo.
  --
  -- Se leen de `get_turn_state`, que ya las calcula para la ruleta. Reusarla es lo que garantiza que
  -- lo que la pantalla mostró y lo que acá se comprueba sean literalmente el mismo código.
  select * into v_estado from public.get_turn_state();

  if v_estado.motivo <> 'disponible' then
    raise exception 'No es turno de canjear: %', v_estado.motivo
      using errcode = 'P0001', detail = v_estado.motivo::text;
  end if;

  -- 4. Las 5 condiciones del beneficio, ya con el lock tomado.
  --
  -- No se reescriben: se le pregunta a `get_available_benefits()` si el beneficio sigue en la lista.
  -- Es la única fuente de verdad (regla de CLAUDE.md), y preguntarle es la única forma de que no
  -- exista una segunda copia de la regla de cupos que se desincronice con la primera.
  --
  -- Cuesta volver a correr la consulta entera para mirar una fila. Se paga con gusto: el día que
  -- alguien cambie cómo se cuentan los cupos, esta función no se entera y sigue siendo correcta.
  if not exists (
    select 1 from public.get_available_benefits() g
    where g.benefit_id = p_benefit_id
  ) then
    -- A propósito sin desglosar si fue cupo, horario o cooldown. Desglosarlo obligaría a reimplementar
    -- los tres predicados acá, que es exactamente lo que esta función evita. La pantalla refresca la
    -- ruleta y el motivo se vuelve evidente solo: la casilla ya no está.
    raise exception 'Ese beneficio ya no está disponible'
      using errcode = 'P0001', detail = 'beneficio_no_disponible';
  end if;

  -- 5. Qué giro se gasta: el que expira antes, y los sin fecha al final.
  --
  -- Los giros de un pase que vence el domingo se pierden igual; los de la suscripción siguen ahí el
  -- lunes. Gastar primero lo que está por vencer es lo que menos desperdicia.
  --
  -- `giros_usados < giros_totales` importa: `giros_usados` sube al VALIDAR, así que un entitlement
  -- puede estar vivo y sin saldo. La puerta de saldo del paso 3 ya garantizó que ALGUNO tiene cupo;
  -- esto elige cuál.
  select e.id into v_ent
  from public.entitlements e
  where e.user_id = v_user
    and e.estado in ('activo', 'pendiente_activacion')
    and (e.fecha_expiracion is null or e.fecha_expiracion > v_ahora)
    and e.giros_usados < e.giros_totales
  order by e.fecha_expiracion asc nulls last, e.created_at asc
  limit 1;

  if v_ent is null then
    -- Si el paso 3 dejó pasar y acá no hay entitlement, saldo y entitlements se contradicen.
    raise exception 'No hay ningún giro disponible para gastar'
      using errcode = 'P0001', detail = 'sin_entitlement';
  end if;

  -- Importante: NO se activa el pase acá. La decisión 12 lo pone en la validación, junto con el giro:
  -- reservar y arrepentirse no puede quemar un día del pase.

  v_ttl    := coalesce(app.setting_int('ttl_codigo_canje_minutos'), 5);
  v_expira := v_ahora + make_interval(mins => v_ttl);

  -- 6. Insertar, reintentando si el código sorteado choca con otro pendiente.
  --
  -- Con 10^6 códigos y un puñado de pendientes vivos a la vez, una colisión es rarísima; igual hay
  -- que contemplarla, porque el índice único la rechaza y sin reintento el usuario vería un error
  -- incomprensible. Se distingue por nombre de índice cuál de las dos unicidades saltó.
  for v_intento in 1..10 loop
    begin
      v_codigo := app.codigo_canje();

      insert into public.redemptions
        (user_id, entitlement_id, benefit_id, merchant_id, codigo, estado,
         created_at, expira_at, franja, dia_operativo)
      values
        (v_user, v_ent, p_benefit_id, v_merchant, v_codigo, 'pendiente',
         v_ahora, v_expira, app.franja_en(v_ahora), app.dia_operativo(v_ahora))
      returning id into v_id;

      exit;
    exception when unique_violation then
      if position('un_pendiente_por_usuario' in coalesce(sqlerrm, '')) > 0 then
        -- Otra sesión del mismo usuario ganó la carrera entre el paso 3 y este insert. La base lo
        -- impide y está bien que lo impida: es la decisión 2 sostenida por el esquema, no por la
        -- confianza en que esta función haya mirado antes.
        raise exception 'Ya tenés un canje abierto'
          using errcode = 'P0001', detail = 'canje_pendiente';
      end if;
      -- Si no fue esa, fue el código repetido: se sortea otro.
      v_id := null;
    end;
  end loop;

  if v_id is null then
    raise exception 'No se pudo generar un código libre'
      using errcode = 'P0001', detail = 'codigo_no_generado';
  end if;

  redemption_id := v_id;
  codigo        := v_codigo;
  expira_at     := v_expira;
  qr_payload    := app.firmar_canje(v_id, v_merchant, v_expira);
  return next;
end;
$$;

comment on function public.create_redemption(uuid) is
  'Reserva un canje: revalida las condiciones con lock, elige el giro que expira antes, emite código de 6 dígitos y QR firmado. NO descuenta el giro ni activa el pase — eso es validate_redemption (T6). Los rechazos van con errcode P0001 y el motivo legible por máquina en DETAIL.';

-- ---------------------------------------------------------------------------
-- `cancel_redemption` — soltar la reserva
--
-- Libera el giro al instante, que es lo que promete la decisión 2 cuando la app le ofrece al usuario
-- cancelar el canje anterior. Queda en `cancelado` y no en `expirado`: los dos liberan igual, pero
-- arrepentirse y que se te venza son dos conductas distintas y en el Hito 4 hay que poder separarlas.
--
-- Un canje ya vencido pero sin marcar también se deja cancelar. Para el usuario es el mismo gesto
-- —"esto ya no lo quiero"— y negárselo por un detalle de contabilidad interna sería absurdo.
-- ---------------------------------------------------------------------------

create or replace function public.cancel_redemption(p_redemption_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user  uuid := (select auth.uid());
  v_dueno uuid;
  v_est   public.redemption_estado;
begin
  if v_user is null then
    raise exception 'Hay que iniciar sesión'
      using errcode = 'P0001', detail = 'sin_sesion';
  end if;

  select r.user_id, r.estado into v_dueno, v_est
  from public.redemptions r
  where r.id = p_redemption_id
  for update;

  -- Un canje de otro usuario se responde igual que uno inexistente, a propósito: si se distinguieran,
  -- probando ids se podría averiguar cuáles existen.
  if v_dueno is null or v_dueno <> v_user then
    raise exception 'Ese canje no existe'
      using errcode = 'P0001', detail = 'canje_inexistente';
  end if;

  if v_est <> 'pendiente' then
    raise exception 'Ese canje ya no está pendiente (está %)', v_est
      using errcode = 'P0001', detail = 'canje_no_pendiente';
  end if;

  update public.redemptions
     set estado = 'cancelado'
   where id = p_redemption_id;
end;
$$;

comment on function public.cancel_redemption(uuid) is
  'Suelta un canje pendiente propio y libera el giro al instante. Queda en estado cancelado, distinto de expirado, para poder separar en los reportes al que se arrepintió del que no llegó a usarlo.';

-- ---------------------------------------------------------------------------
-- Permisos
--
-- Las dos son SECURITY DEFINER y comprueban `auth.uid()` adentro: el usuario no escribe en
-- `redemptions` por RLS —la 005 dejó la escritura cerrada a propósito— sino a través de estas puertas,
-- que son las que saben contar cupos y tomar el lock.
--
-- `app.firmar_canje` y `app.codigo_canje` NO se otorgan a nadie: viven en `app`, que PostgREST no
-- publica, y la primera lee secretos de comercio.
-- ---------------------------------------------------------------------------

revoke all on function public.create_redemption(uuid) from public;
revoke all on function public.cancel_redemption(uuid) from public;

grant execute on function public.create_redemption(uuid) to authenticated;
grant execute on function public.cancel_redemption(uuid) to authenticated;
