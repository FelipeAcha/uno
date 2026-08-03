# TRIADA

MVP de una aplicación personal para observar el balance entre tres dominios de vida:

- `SELF`: bienestar, salud, recuperación, recreación y desarrollo personal.
- `WORK`: trabajo individual, colaborativo, operativo y estratégico.
- `RELATIONSHIPS`: familia, amistades, pareja, cuidado y responsabilidades relacionales.

## Estado

MVP operativo iniciado el 3 de agosto de 2026.

## Principios

1. Una sola vida integrada; el trabajo no se optimiza a costa de salud o vínculos.
2. Objetivo semanal inicial cercano a 1/3 por dominio, usado como hipótesis y no como dogma.
3. Los días pueden ser desiguales; el sistema gobierna tendencias semanales.
4. Cada bloque tiene un dominio primario y etiquetas secundarias para evitar doble conteo.
5. Toda inferencia debe indicar evidencia: `MEASURED`, `ESTIMATED` o `SELF_REPORTED`.
6. La aplicación debe liberar más tiempo del que consume.

## Privacidad

Este repositorio contiene solo código, esquemas y datos de ejemplo. No debe incluir calendarios reales, nombres de terceros, estados emocionales, métricas personales, enlaces privados ni exportaciones de Google Drive. Los datos de producción permanecen en almacenamiento personal privado.

## Uso rápido

```bash
python3 triada/src/triada_balance.py triada/examples/activity_log.example.csv
```

El comando calcula minutos y porcentajes por dominio, evalúa el corredor diario piloto de 18%–48% y muestra alertas simples.

## Estructura

- `config/calendar_colors.json`: taxonomía de colores de Google Calendar.
- `examples/activity_log.example.csv`: datos ficticios.
- `src/triada_balance.py`: cálculo mínimo de balance.
- `tests/test_triada_balance.py`: pruebas del núcleo.

## Próximos incrementos

1. Importador de Google Calendar.
2. Integración local con ActivityWatch sin capturar contenido.
3. Cálculo semanal y tendencia móvil.
4. Métrica de uso neto de IA: tiempo manual probable menos uso activo y retrabajo.
5. Interfaz local mínima.
