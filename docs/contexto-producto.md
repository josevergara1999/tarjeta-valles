# Contexto de producto — el porqué de cada decisión

Este documento no describe *qué* hace el sistema (eso está en `spec-app-tarjeta.md`), sino **por qué está diseñado así**. Cada regla acá resolvió un problema concreto. Si una implementación parece innecesariamente compleja, la razón probablemente esté en esta página.

---

## El problema que resuelve

En una zona turística hay dos necesidades desatendidas al mismo tiempo:

- **El visitante** llega, no conoce nada, y termina siempre en los dos lugares que vio en Instagram.
- **El comercio** tiene días y horas muertas (un martes de junio, un almuerzo de jueves) y no tiene cómo llenarlas sin bajar sus precios públicos ni gastar en publicidad.

La tarjeta conecta ambas: el visitante recibe beneficios reales para descubrir lugares nuevos; el comercio recibe clientes justo cuando los necesita. El negocio cobra por conectarlos.

---

## Decisiones y su razón

### Una sola mecánica: la ruleta

**Se descartó** el modelo de "descuentos permanentes + cortesías" en dos capas. Motivo: obligaba al comercio a un doble sacrificio (un % ilimitado para siempre *más* una cortesía), y el % permanente era el que más miedo daba porque no tenía tope.

Con todo dentro de la ruleta, **todo tiene cupos**. Nada es ilimitado. El comercio entra con un solo compromiso acotado.

### El usuario elige, no es azar

Es una ruleta en la *presentación* (visual, entretenida), pero el usuario ve las casillas y decide dónde cae. Se descartó el azar real porque frustra: "me tocó algo que no quiero" es una mala experiencia, y el producto ya prometía control al usuario.

### Cooldown de 3 días, con contador visible

Al canjear en un local, ese local se apaga 3 días para ese usuario y luego vuelve.

- **Por qué existe:** empuja a descubrir otros locales (el objetivo de circulación) y protege al comercio de un usuario que iría todos los días.
- **Por qué reaparece y no se bloquea para siempre:** en un pase de 14 días, "sin repetir jamás" agota las opciones y la ruleta muere justo con el cliente más valioso.
- **Por qué el contador es visible:** convierte la restricción en anticipación. El que amó la cervecería espera que vuelva a habilitarse — eso *fabrica regreso* al local, que es exactamente lo que se le prometió al comercio.

### Los giros son la moneda, y la suscripción da un paquete mensual

Se descartó "giros diarios ilimitados para suscriptores": serían 60 beneficios al mes por $5.000 = $83 por beneficio. Ningún local aguanta eso; el suscriptor intensivo destruiría la red.

Con 8 giros/mes son $625 por beneficio (sostenible) y equivalen a dos salidas por semana, más de lo que un residente realmente sale.

**Los giros no se acumulan entre ciclos** porque si se guardan, se juntan 40 para la semana de nieve y saturan a todos los locales el mismo fin de semana.

### El giro se reserva al elegir y se descuenta al validar

Tres problemas resueltos de una vez:
- El usuario no puede reutilizar un screenshot (el código expira en 5 minutos).
- El comercio no puede fabricar canjes falsos (el código lo genera el sistema).
- Si el usuario se arrepiente o el local está cerrado, no pierde el giro.

### Los cupos, horarios y el switch de activo/inactivo son del comercio

El miedo del dueño nunca es "regalar un postre": es **no poder controlar cuántos regala**. Por eso él define cupos por día/semana, ventanas horarias (para llenar horas muertas, no los sábados llenos) y puede apagar su beneficio cuando quiera desde su panel. El beneficio es una **campaña que él enciende y apaga**, no un contrato.

### Todo beneficio va condicionado al consumo

Nunca "postre gratis": siempre "postre con plato principal". El local nunca regala sin venta — su costo real es el insumo y a cambio recibió una cuenta completa. Por eso la condición de consumo es un campo **obligatorio** y se muestra siempre junto al beneficio: evita el 90% de los conflictos en el mostrador.

### El ranking mide satisfacción, no generosidad

**El error que se detectó y corrigió a tiempo:** si el ranking premiara al que da el mejor beneficio, el más generoso se saturaría de gente y se arrepentiría de haber entrado. El sistema castigaría al que colabora.

Por eso el orden se calcula con **valoración de los usuarios que canjearon y tasa de retorno al local**, no con el tamaño del beneficio. Un restaurante puede ser primero de su categoría con solo un 10% de descuento si la gente sale feliz. La saturación no se arregla con el ranking: se arregla sola con los cupos.

### La tarjeta física se gana, nunca se vende

Es la prueba de que el usuario fue, volvió y pertenece. Si se pudiera comprar, la barra de progreso pierde sentido y el que la ganó con 30 visitas se siente estafado: pasa de símbolo de pertenencia a souvenir.

**Se retira presencialmente en un local de la red**, no se despacha:
- Cero costo de envío (en Chile son $3.000-4.000, se comían el margen).
- La entrega en mano es un momento memorable y filmable (contenido para redes).
- El que quedó a dos canjes de su tarjeta tiene un motivo concreto para volver al valle.

Los niveles dan **más giros al mes** (+2 / +4 / +6). El estatus tiene que ser concreto y medible, no "beneficios superiores" en abstracto.

### Giftcards: un producto por canal

En el mesón del local se vende **solo la giftcard de pase de 3 días**. Motivo: el cajero no puede segmentar — no sabe ni debe preguntar si el regalo es para un turista o para alguien de la zona. Un mostrador con dos productos que exigen esa distinción es un mostrador donde no se ofrece ninguno.

La giftcard de **membresía existe solo online**, donde el comprador sí sabe para quién es. Si estuvieran juntas en el mesón, el turista compararía "pase 3 días $4.900 vs mes completo $5.000" y el pase moriría.

El código va **inactivo hasta la venta** y se activa desde el panel del comercio: el stock sin activar es papel sin valor, así el local no arriesga nada.

Al vencer el período regalado **no hay renovación automática**, hay invitación: "ya llevas 6 canjes hacia tu tarjeta física — continúa y no pierdas tu progreso". La giftcard es un trial pagado por otra persona.

### Los hospedajes son caso aparte

Un hospedaje no puede dar "descuento en la noche" en la ruleta: el huésped ya reservó, llegó y pagó. Sus beneficios de ruleta son los que se consumen estando alojado (late checkout, upgrade, tinaja fuera de horario). Los de reserva futura (% en la próxima estadía) van asociados a los niveles de tarjeta física, no a la ruleta diaria.

Su valor real es otro: es el único actor con el cliente **confirmado y contactable semanas antes de llegar**, lo que lo convierte en el mejor canal de venta de pases.

### Nunca prometer personas al comercio

No se dice "este fin de semana van a ir 20": es un pronóstico que no se controla, y si llegan 6 se pierde la credibilidad. Se dice **"tienes 20 cupos publicados"**, que es un hecho que él configuró. Cada cupo usado es un cliente que llegó y consumió; si no se usa ninguno, no le costó nada.

Esto tiene implicancia de producto: el panel debe mostrar **cupos publicados y canjes reales**, nunca proyecciones.

### El posicionamiento pagado no vende el ranking

Cuando se active la monetización B2B (fase posterior), los espacios pagados son **separados y marcados** como destacados, arriba de la lista orgánica — el modelo de Google. El ranking por mérito nunca se vende: si se vendiera el primer lugar, se pierde la credibilidad ante comercios y usuarios de una sola vez.

---

## Precios (referencia)

| Producto | Giros | Precio | Por beneficio |
|---|---|---|---|
| Bienvenida (QR) | 1 de prueba | Gratis | — |
| Pase del Día | 3 | $2.990 | $997 |
| Pase 3 días | 9 | $4.900 | $544 |
| Pase 7 días | 21 | $7.900 | $376 |
| Pase 14 días | 42 | $12.900 | $307 |
| Suscripción mensual | 8/mes | $5.000/mes | $625 |
| Suscripción anual | 10/mes | $3.000/mes | $300 |

La curva es intencional: mientras más comprometido con el valle, más barato sale cada beneficio. El Pase del Día existe en parte como **ancla** para que el de 3 días se vea regalado.

**La columna de giros se corrigió el 30-ago-2026** para que respete la decisión 11: un pase de N días trae N × 3 giros, porque el día se parte en tres franjas y cada franja da un giro. Confirmado por José: *"el pase diario tiene 1 ruleta; 1 giro significa 3 giros a lo largo del día, mañana, tarde y noche"*. Los números viejos —1, 3, 7 y 12— eran de antes de esa decisión y estaban un factor de tres por debajo.

Las suscripciones **no** se multiplican: sus 8 y 10 giros son una bolsa mensual, y la franja es un techo de ritmo, no una fuente de giros. Un suscriptor gasta como máximo 3 al día y 1 por franja, pero sigue teniendo 8 al mes.

> **PENDIENTE DE PRECIO — los precios de esta tabla NO se tocaron, solo los giros.**
> Con la columna corregida, el Pase 14 sale a $307 por beneficio contra **$625 de la suscripción
> mensual**: el pase largo la deja sin sentido, y el de 7 días ($376) también la pasa por encima.
> La suscripción anual ($300) es lo único que se sostiene abajo del pase largo, y por muy poco.
>
> Puede ser una decisión correcta —el turista está pocos días y quiere exprimirlos, y la suscripción
> se defiende por ser para residentes todo el año— pero es una **decisión de precio y de salud de la
> red que hay que tomar aparte**. Mientras no se tome, esta tabla describe cuántos giros entrega cada
> producto, no cuánto debería costar. Ver `decisiones-hito-1.md`, decisión 11.
