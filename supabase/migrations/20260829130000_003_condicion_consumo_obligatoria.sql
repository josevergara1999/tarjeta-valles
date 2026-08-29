-- Migración 003 — La condición de consumo es obligatoria
-- Hito 1 · T2 (corrección). Referencias: docs/spec-app-tarjeta.md, docs/decisiones-hito-1.md.
--
-- La 002 dejó `condicion_consumo` nullable porque la tabla de docs/seed-data.md trae tres
-- beneficios con la condición en blanco. El spec dice que es obligatoria y la regla dura 4 del
-- proyecto también: un beneficio nunca se muestra sin su condición al lado. Manda el spec.
--
-- Un beneficio que de verdad no impone nada no queda sin texto: lo dice. "Sin condiciones" es una
-- condición de consumo perfectamente válida, y además es la que el cliente quiere leer parado
-- frente al mesón. Lo que no puede pasar es que el campo llegue vacío a la pantalla.

-- Los tres de la semilla que venían con la condición en blanco (#3 Café Bosque, #7 Termas del Sur,
-- #8 Gimnasio Andino). El backfill va antes del NOT NULL, o el ALTER no pasa.
update public.benefits
set condicion_consumo = 'Sin condiciones'
where condicion_consumo is null;

alter table public.benefits
  alter column condicion_consumo set not null;

-- El CHECK de la 002 contemplaba el nulo; ya no hace falta. Queda solo la parte que importa: que
-- no entre una cadena en blanco, que es lo que dejaría a la interfaz dibujando una etiqueta vacía.
alter table public.benefits
  drop constraint benefits_condicion_no_vacia;

alter table public.benefits
  add constraint benefits_condicion_no_vacia
  check (length(btrim(condicion_consumo)) > 0);

comment on column public.benefits.condicion_consumo is
  'La letra chica que SIEMPRE se muestra junto al título ("con la segunda ronda"). Obligatoria: un beneficio sin condición declara "Sin condiciones", nunca se queda en blanco.';
