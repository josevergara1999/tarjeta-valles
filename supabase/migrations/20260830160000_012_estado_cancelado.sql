-- Migración 012 — El estado `cancelado`
-- Hito 1 · T5. Referencia: docs/decisiones-hito-1.md, menores.
--
-- Cancelar y expirar liberan el giro igual, así que hoy esto no cambia nada visible. La diferencia
-- aparece en los reportes del Hito 4: mucha cancelación significa que la gente duda al elegir en la
-- ruleta, y mucha expiración significa que llegó al local y no la atendieron. Son dos problemas
-- distintos con dos soluciones distintas, y si los canjes se guardan todos como `expirado` esa
-- distinción no se puede reconstruir después: el dato no existe.
--
-- ESTA MIGRACIÓN VA SOLA, Y NO ES CAPRICHO. Postgres no deja usar un valor de enum recién agregado
-- dentro de la misma transacción que lo agregó ("unsafe use of new value of enum type"). El CLI de
-- Supabase envuelve cada migración en una transacción, así que agregar el valor y escribir la función
-- que lo usa en un solo archivo revienta al aplicar. El valor se agrega acá; la 013 ya lo puede usar.

alter type public.redemption_estado add value 'cancelado';

comment on type public.redemption_estado is
  'Los cinco finales de un canje. `pendiente` es la reserva viva; `validado` lo consumió el local; `expirado` se le venció al usuario sin usarlo; `cancelado` lo soltó él a propósito; `anulado` lo deshizo el admin con motivo. Los tres últimos liberan el giro, pero por razones distintas y eso importa en los reportes.';

-- `app.redemption_ocupa` NO se toca. Está escrita como lista blanca —ocupa el validado y el pendiente
-- vigente, y nada más— así que un `cancelado` deja de ocupar cupo solo, sin tener que acordarse de
-- actualizarla. Vale la pena notarlo: si estuviera escrita como lista negra ("todos menos expirado y
-- anulado"), agregar este valor habría abierto un agujero silencioso en el conteo de cupos.
