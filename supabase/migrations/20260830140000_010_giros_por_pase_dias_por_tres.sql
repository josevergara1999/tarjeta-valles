-- Migración 010 — Los giros de cada pase son días × 3
-- Hito 1 · corrección de la semilla de T3. Referencia: docs/decisiones-hito-1.md, decisión 11.
--
-- La 005 dejó los `giros_totales` de los pases semilla como relleno de prueba —pase de 7 días con 8
-- giros, pase de 3 días con 4— y lo dijo en un comentario: cuánto vale cada producto en giros no
-- estaba definido en ninguna parte.
--
-- Ya está definido. José lo confirmó el 30-ago-2026: el pase diario trae una ruleta, y una ruleta
-- son tres giros repartidos en las tres franjas del día —mañana, tarde y noche—. Un pase de N días
-- trae, entonces, N × 3 giros:
--
--     Pase del Día  3   ·   Pase 3 días  9   ·   Pase 7 días  21   ·   Pase 14 días  42
--
-- Las suscripciones NO se multiplican y por eso no se tocan acá: sus 8 y 10 giros mensuales son una
-- bolsa, no un derecho diario. La franja les pone un techo de ritmo —3 al día como máximo, 1 por
-- franja— pero no les regala giros. Es la distinción de la decisión 11: la franja es un techo, no
-- una fuente.
--
-- Lo que esta migración NO resuelve: el precio. Con 42 giros el Pase 14 sale a $307 por beneficio
-- contra $625 de la suscripción mensual, y eso deja al pase largo compitiendo con la suscripción y
-- ganándole. Es una decisión de precio y de salud de la red, está anotada como pendiente en la
-- decisión 11, y no se toma desde una migración.

-- ---------------------------------------------------------------------------
-- Los dos pases de la semilla
--
-- Solo estos dos: son los únicos entitlements de tipo pase que existen. Se filtran por su id fijo
-- `5eed0003-…` para que esto no toque jamás un entitlement real si algún día conviven. `where`
-- explícito por id y no por `tipo`, porque un update masivo por tipo sería una bomba el día que
-- entren usuarios de verdad.
--
-- `giros_usados` no se toca: el turista lleva 3 canjes hechos y el pase vencido 3, y esos canjes
-- existen en `redemptions`. Subir solo el techo mantiene la coherencia y respeta el check
-- `entitlements_saldo` (usados <= totales), que con 3 <= 21 y 3 <= 9 se cumple de sobra.
-- ---------------------------------------------------------------------------

update public.entitlements
   set giros_totales = 21
 where id = '5eed0003-0000-4000-a000-000000000002'
   and tipo = 'pase_7';

update public.entitlements
   set giros_totales = 9
 where id = '5eed0003-0000-4000-a000-000000000005'
   and tipo = 'pase_3';

-- ---------------------------------------------------------------------------
-- Comprobación
--
-- Si la semilla de la 005 no estaba cargada, los updates de arriba no hacen nada y la migración
-- pasaría en silencio dejando la base en un estado que nadie revisó. Mejor que reviente acá.
--
-- El pase vencido sigue siendo la prueba del giro perdido, y ahora con más fuerza: 9 giros, 3
-- usados, 6 que se perdieron al expirar (spec 3.3). El escenario no se debilita, se agranda.
-- ---------------------------------------------------------------------------

do $$
declare
  v_pase_7 integer;
  v_pase_3 integer;
begin
  select giros_totales into v_pase_7
    from public.entitlements where id = '5eed0003-0000-4000-a000-000000000002';
  select giros_totales into v_pase_3
    from public.entitlements where id = '5eed0003-0000-4000-a000-000000000005';

  if v_pase_7 is null or v_pase_3 is null then
    raise exception 'La semilla de entitlements de la 005 no está cargada: no hay qué corregir.';
  end if;

  if v_pase_7 <> 21 or v_pase_3 <> 9 then
    raise exception 'Los giros no quedaron en días × 3 (pase_7 = %, pase_3 = %).', v_pase_7, v_pase_3;
  end if;

  raise notice 'OK · pase_7 = 21 giros (7 días × 3), pase_3 = 9 giros (3 días × 3).';
end $$;
