# Datos semilla (seed) — desarrollo y pruebas

Datos ficticios pero realistas para poblar la base en desarrollo. Los nombres son inventados: **no usar nombres de comercios reales de Las Trancas** hasta tener su autorización firmada.

## Rubros

`restaurante` · `cerveceria` · `hospedaje` · `minimarket` · `rental` · `gimnasio` · `otro`

## Comercios de prueba

| # | Nombre | Rubro | Beneficio | Condición de consumo | Tipo | Cupos/día | Días | Horario |
|---|---|---|---|---|---|---|---|---|
| 1 | Fogón del Valle | restaurante | Postre de cortesía | con plato principal | cortesía | 6 | Lun-Jue | 12:00–16:00 |
| 2 | Cervecería Nevado | cerveceria | Schop de cortesía | con la segunda ronda | cortesía | 10 | Mar-Dom | 17:00–21:00 |
| 3 | Café Bosque | restaurante | 15% en la cuenta | — | descuento | sin tope | Todos | 08:00–13:00 |
| 4 | Rental Trancas | rental | 15% en el arriendo | arriendo de día completo | descuento | 8 | Todos | 08:00–12:00 |
| 5 | Minimarket El Paso | minimarket | 10% en la compra | compras sobre $15.000 | descuento | sin tope | Todos | 09:00–21:00 |
| 6 | Cabañas Mirador | hospedaje | Late checkout 14:00 | sujeto a disponibilidad | cortesía | 2 | Todos | — |
| 7 | Termas del Sur | otro | 20% en la entrada | — | descuento | 15 | Lun-Vie | 10:00–18:00 |
| 8 | Gimnasio Andino | gimnasio | Clase grupal incluida | — | cortesía | 4 | Lun-Vie | 07:00–20:00 |

Casos que estos datos permiten probar:
- Cupos con tope vs sin tope (#3 y #5 sin tope)
- Ventanas horarias distintas y beneficios fuera de horario
- Beneficio sin condición de consumo (#3, #5, #7) — la UI debe manejar el campo vacío
- Hospedaje sin ventana horaria (#6)
- Cupos muy bajos que se agotan rápido (#6, con 2)

## Usuarios de prueba

| Rol | Teléfono | Estado |
|---|---|---|
| Usuario nuevo | +56 9 1111 1111 | Sin entitlements — para probar onboarding y giro de bienvenida |
| Turista con pase | +56 9 2222 2222 | Pase 7 días activo, 3 giros usados, 2 canjes en cooldown |
| Suscriptor | +56 9 3333 3333 | Suscripción mensual, 5 de 8 giros usados, 8 canjes históricos (cerca de Nivel 1) |
| Nivel 1 | +56 9 4444 4444 | 34 canjes históricos, tarjeta Nivel 1 retirada, +2 giros/mes |
| Pase expirado | +56 9 5555 5555 | Pase 3 días vencido con 1 giro sin usar — para probar expiración |

## Cuentas de comercio

| Email | Rol | Comercio |
|---|---|---|
| dueno@fogon.test | dueno | Fogón del Valle |
| caja@fogon.test | operador | Fogón del Valle |
| dueno@nevado.test | dueno | Cervecería Nevado |

## Escenarios de prueba obligatorios

1. **Canje feliz:** usuario elige → código → comercio valida → giro descontado, progreso +1
2. **Código expirado:** pasan 5 min sin validar → giro liberado, casilla vuelve a estar disponible
3. **Cupo agotado:** el cupo N+1 del día no puede reservarse; la casilla se ve apagada con "Agotado por hoy"
4. **Cooldown:** un usuario que canjeó ayer en #2 ve esa casilla apagada con "Vuelve en 2 días"
5. **Fuera de horario:** #1 no aparece disponible un sábado ni a las 20:00
6. **Sin giros:** usuario con 0 giros disponibles ve la ruleta pero no puede reservar
7. **Aislamiento (RLS):** la cuenta de Fogón no puede leer canjes ni clientes de Nevado
8. **Doble validación:** el mismo código no puede validarse dos veces
9. **Código de otro comercio:** Nevado no puede validar un código generado para Fogón
10. **Sin conexión:** el panel guarda el canje en cola y sincroniza al recuperar señal
11. **Desbloqueo de nivel:** al llegar a 10 canjes se crea el desbloqueo y aparece dónde retirar
12. **Giftcard:** activación en local → canje por el receptor → entitlement creado

## Parámetros iniciales (tabla `settings`)

```
cooldown_dias_default = 3
ttl_codigo_canje_minutos = 5
canjes_nivel_1 = 10
canjes_nivel_2 = 35
canjes_premium = 100
giros_extra_nivel_1 = 2
giros_extra_nivel_2 = 4
giros_extra_premium = 6
giros_suscripcion_mensual = 8
giros_suscripcion_anual = 10
comision_giftcard = 0.10
```
