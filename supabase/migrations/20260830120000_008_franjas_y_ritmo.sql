-- Migración 008 — Las franjas del día y el ritmo de giros
-- Hito 1 · T4 (base). Referencia: docs/decisiones-hito-1.md, decisión 11.
--
-- El día se parte en tres franjas —mañana, tarde y noche— y el usuario tiene un giro por franja.
-- La promesa del producto es una jornada planificada (rental en la mañana, almuerzo, cervecería al
-- cierre), así que la franja es una regla que el sistema HACE CUMPLIR, no una sugerencia de
-- pantalla: nadie quema los tres giros en el almuerzo.
--
-- Esta migración solo pone los cimientos: parámetros, columnas y el cálculo de franja y día
-- operativo. Quién puede canjear qué es `get_available_benefits`, en la 009.

-- ---------------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------------

create type public.franja_dia as enum ('manana', 'tarde', 'noche');

comment on type public.franja_dia is
  'Las tres etapas de la jornada. Sin acento en `manana` a propósito: es un valor de enum que viaja al cliente y a los índices, no un texto de interfaz.';

-- ---------------------------------------------------------------------------
-- Parámetros
--
-- Las franjas se definen SOLO por su hora de inicio, encadenadas: la mañana termina donde empieza
-- la tarde, la tarde donde empieza la noche, y la noche donde empieza la mañana del día siguiente.
-- Guardar inicio y fin de cada una permitiría sembrar huecos ("nada entre 12:00 y 12:30") o solapes
-- ("las 20:00 son tarde y noche a la vez"). Encadenándolas eso es imposible por construcción.
-- ---------------------------------------------------------------------------

insert into public.settings (key, value, tipo, descripcion) values
  ('franja_manana_inicio', '06:00', 'texto',
   'Hora en que empieza la mañana. Marca también el comienzo del día operativo: un canje anterior a esta hora cuenta para el día anterior.'),
  ('franja_tarde_inicio',  '12:00', 'texto',
   'Hora en que la mañana se convierte en tarde.'),
  ('franja_noche_inicio',  '19:00', 'texto',
   'Hora en que la tarde se convierte en noche. La noche cruza medianoche y termina donde empieza la mañana.'),
  ('modo_ritmo_giros',     'franjas', 'texto',
   'Cómo se reparte el gasto dentro de un día. `franjas`: un giro por franja. `libre`: hasta giros_por_dia canjes cuando el usuario quiera. Cambiar de modo es un update acá, sin migración ni despliegue.'),
  ('giros_por_dia',        '3', 'entero',
   'Techo de canjes por día operativo en modo `libre`. En modo `franjas` el techo lo dan las franjas y este valor no se lee.'),
  ('zona_horaria',         'America/Santiago', 'texto',
   'Zona del valle. Toda conversión de instante a día y a franja pasa por acá; nunca por la zona del servidor ni por la del teléfono.');

-- El modo tiene dos valores y solo dos. Un typo en un update ('franja', 'libres') dejaría a
-- get_available_benefits eligiendo una rama por descarte, que es la peor forma de fallar.
alter table public.settings
  add constraint settings_modo_ritmo_valido
  check (key <> 'modo_ritmo_giros' or value in ('franjas', 'libre'));

-- Las tres franjas tienen que ser horas válidas. Un 'mediodia' o un '25:00' no se descubriría acá:
-- se descubriría en producción, con la ruleta vacía y sin explicación.
alter table public.settings
  add constraint settings_franja_hora_valida
  check (key not in ('franja_manana_inicio', 'franja_tarde_inicio', 'franja_noche_inicio')
         or value ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$');

-- ---------------------------------------------------------------------------
-- Cálculo de franja y de día operativo
--
-- El día operativo empieza cuando empieza la mañana (06:00), no a medianoche. Eso resuelve de una
-- sola vez lo que pide la decisión 6 —"el canje de la 01:00 pertenece al día anterior para efectos
-- de cupos"— y hace que la cervecería de 21:00 a 02:00 funcione sin ningún caso especial: su
-- clientela de la 01:00 sigue dentro de la misma noche y del mismo día para los cupos.
--
-- Una sola definición de "día" en todo el sistema. Si mañana se mueve el inicio de la mañana, se
-- mueven juntos el corte de los cupos y el de las franjas, que es lo correcto.
-- ---------------------------------------------------------------------------

create function app.zona_horaria()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(app.setting_text('zona_horaria'), 'America/Santiago');
$$;

comment on function app.zona_horaria() is
  'El coalesce no es decorativo: si alguien borra la fila de settings, es preferible que el sistema siga contando en la zona del valle a que devuelva nulo y deje toda condición horaria en indeterminado, que en SQL se comporta como "no disponible" para todos.';

create function app.hora_local(p_ts timestamptz)
returns time
language sql
stable
security definer
set search_path = ''
as $$
  select (p_ts at time zone app.zona_horaria())::time;
$$;

create function app.franja_en(p_ts timestamptz)
returns public.franja_dia
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when t.h >= app.setting_text('franja_noche_inicio')::time  then 'noche'::public.franja_dia
    when t.h >= app.setting_text('franja_tarde_inicio')::time  then 'tarde'::public.franja_dia
    when t.h >= app.setting_text('franja_manana_inicio')::time then 'manana'::public.franja_dia
    -- Antes de que empiece la mañana: son las 02:00 y todavía es la noche de ayer.
    else 'noche'::public.franja_dia
  end
  from (select app.hora_local(p_ts) as h) t;
$$;

comment on function app.franja_en(timestamptz) is
  'En qué franja cae un instante. Las 02:00 son noche —la de ayer—, no mañana: por eso el else cierra en noche y no en manana.';

create function app.dia_operativo(p_ts timestamptz)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when app.hora_local(p_ts) >= app.setting_text('franja_manana_inicio')::time
      then (p_ts at time zone app.zona_horaria())::date
    -- Madrugada: todavía es el día anterior. Es la decisión 6, escrita una sola vez.
    else (p_ts at time zone app.zona_horaria())::date - 1
  end;
$$;

comment on function app.dia_operativo(timestamptz) is
  'El día del negocio, que empieza a las 06:00 y no a medianoche. Es el corte que usan los cupos diarios, el cupo semanal y el techo de giros del usuario.';

-- El lunes de la semana operativa. La semana de los cupos es lunes a domingo, y date_trunc('week')
-- ya usa esa convención en Postgres.
create function app.semana_operativa(p_ts timestamptz)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select (date_trunc('week', app.dia_operativo(p_ts)::timestamp))::date;
$$;

grant execute on function
  app.zona_horaria(),
  app.hora_local(timestamptz),
  app.franja_en(timestamptz),
  app.dia_operativo(timestamptz),
  app.semana_operativa(timestamptz)
  to authenticated;

-- ---------------------------------------------------------------------------
-- redemptions guarda su franja y su día
--
-- Ambos se podrían recalcular desde created_at, y aun así se guardan. Dos razones:
--
-- 1. Estabilidad histórica. Si algún día la tarde empieza a las 13:00, recalcular movería de franja
--    a todos los canjes ya hechos y "¿ya gastó la tarde?" respondería distinto sobre el pasado.
--    Un canje se hizo en la franja que estaba vigente cuando se hizo, y eso no cambia después.
-- 2. Conteo. app.dia_operativo() no es inmutable —lee settings—, así que no puede entrar en un
--    índice. Con la columna, contar cupos es una igualdad indexable en vez de una conversión de
--    zona horaria fila por fila.
--
-- Las escribe T5 al insertar. Las filas que ya existen —los canjes semilla de T3— se rellenan más
-- abajo a partir de su `created_at`, que es el instante real en que ocurrieron. Eso no contradice
-- lo anterior: congelar la franja protege contra cambios FUTUROS de horario, no contra calcularla
-- una primera vez con las reglas vigentes hoy.
-- ---------------------------------------------------------------------------

alter table public.redemptions
  add column franja        public.franja_dia,
  add column dia_operativo date;

comment on column public.redemptions.franja is
  'La franja vigente al crear el canje, congelada. No se recalcula: mover el horario de las franjas no puede reescribir el pasado.';

comment on column public.redemptions.dia_operativo is
  'El día del negocio al que pertenece el canje (empieza a las 06:00). Un canje de la 01:00 cuenta para el día anterior, decisión 6.';

-- Los canjes que ya existen reciben su franja y su día calculados desde el instante en que se
-- crearon. Sin esto, los cupos de la semilla de T3 quedarían invisibles para T4 y las pruebas de
-- los escenarios de seed-data.md contarían mal.
update public.redemptions
set franja        = app.franja_en(created_at),
    dia_operativo = app.dia_operativo(created_at)
where franja is null;

-- Los dos van juntos o no va ninguno: media fila deja el conteo de cupos sin saber a qué día sumar.
alter table public.redemptions
  add constraint redemptions_franja_y_dia_juntos
  check ((franja is null) = (dia_operativo is null));

-- El conteo de cupos de T4: cuántos canjes vivos tiene este beneficio hoy.
create index redemptions_benefit_dia_idx
  on public.redemptions (benefit_id, dia_operativo, estado);

-- El techo de ritmo de T4: qué franjas gastó este usuario hoy.
create index redemptions_user_dia_franja_idx
  on public.redemptions (user_id, dia_operativo, franja, estado);
