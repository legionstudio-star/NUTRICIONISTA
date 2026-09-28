# Plataforma de Encuestas – Nutrición

Aplicación web estática (un solo `index.html`, publicada con **GitHub Pages**) con dos encuestas:

1. **Encuesta de satisfacción del ciclo de menú** (`survey_type = 'satisfaccion'`)
2. **Cuestionario de concertación del ciclo de menús** para padres de familia (`survey_type = 'concertacion'`)

Las respuestas se guardan en **Supabase (PostgreSQL)**. El **panel de la nutricionista** usa **Supabase Auth** (correo + contraseña) y solo lo pueden abrir las cuentas registradas en la tabla `admin_users`.

No hay servidor propio ni proceso de compilación: HTML + CSS + JavaScript puro, con la librería `@supabase/supabase-js` cargada desde CDN (jsDelivr).

---

## Arquitectura y seguridad

| Quién | Qué puede hacer |
|---|---|
| Visitante anónimo (padre de familia, usuario del servicio) | **Solo insertar** una respuesta. No puede leer, editar ni borrar nada. |
| Usuario autenticado que **no** está en `admin_users` | Insertar respuestas. No puede leer ninguna respuesta. |
| Nutricionista (autenticada **y** registrada en `admin_users`) | Leer todas las respuestas, recibir actualizaciones en vivo, borrar respuestas y migrar datos antiguos. |

Cómo se aplica:

- **RLS** activado en `survey_responses` y `admin_users`.
- El rol `anon` **no tiene permiso de SELECT** sobre `survey_responses` (se revoca también a nivel de tabla, además de RLS).
- La lectura se permite solo si `private.is_admin()` es verdadero, es decir, si `auth.uid()` está en `admin_users`.
- `private.is_admin()` es una función `SECURITY DEFINER` con `search_path` fijo, ubicada en un esquema `private` que **no está expuesto** por la API.
- Los visitantes no pueden fijar `created_at`: la fecha oficial la pone el servidor.
- No existe política de UPDATE: una respuesta no se puede modificar después de enviarse.
- **Realtime** respeta RLS: solo las administradoras reciben los eventos de nuevas respuestas.
- En el frontend solo va la **anon / publishable key**, que es pública por diseño. La `service_role` / secret key **nunca** debe ir en el repositorio.

### Estructura de `survey_responses`

| Columna | Tipo | Descripción |
|---|---|---|
| `id` | uuid PK | `gen_random_uuid()` |
| `created_at` | timestamptz | Fecha oficial de la respuesta (servidor) |
| `survey_type` | text | `satisfaccion` o `concertacion` |
| `survey_title` | text | Título de la encuesta |
| `score` | integer | Índice 0–100. Solo en satisfacción; `NULL` en concertación |
| `answers` | jsonb | Respuestas completas (índices de opción o texto libre, por id de pregunta) |
| `source` | text | `web`, `cola_local` (reenvío automático) o `migracion_local` |
| `legacy_id` | text UNIQUE | Id generado en el navegador; evita duplicados en reintentos y migraciones |

### Privacidad

- No se piden nombres, documentos, correos ni ningún dato identificable de quien responde.
- No se guarda IP, navegador ni otros metadatos del dispositivo.
- La pregunta sobre alergias o intolerancias es **orientativa** y no reemplaza la historia clínica ni el reporte formal a la institución.

---

## Puesta en marcha paso a paso

### 1. Crear (o reactivar) el proyecto en Supabase
En <https://supabase.com/dashboard> crea un proyecto nuevo, o reactiva uno pausado con **Resume project**. Espera a que el estado sea *Healthy*.

### 2. Ejecutar `supabase_schema.sql`
1. Abre **SQL Editor → New query**.
2. Pega el contenido completo de [`supabase_schema.sql`](supabase_schema.sql).
3. Pulsa **Run**. Debe terminar con *Success. No rows returned*.

El script es idempotente: puedes ejecutarlo de nuevo sin problema.

### 3. Crear el usuario de la nutricionista
1. Ve a **Authentication → Users → Add user → Create new user**.
2. Escribe su correo y una contraseña segura, y marca **Auto Confirm User**.
3. **Recomendado:** en **Authentication → Sign In / Providers → Email**, desactiva **Allow new users to sign up**. Así nadie más puede crear cuentas desde fuera. Aunque alguien lo hiciera, no podría leer datos porque no estaría en `admin_users`.

### 4. Agregar su UUID a `admin_users`
En el **SQL Editor** ejecuta, cambiando el correo:

```sql
insert into public.admin_users (user_id)
select id from auth.users where email = 'correo-de-la-nutricionista@ejemplo.com'
on conflict (user_id) do nothing;
```

También puedes copiar el **User UID** desde *Authentication → Users* y hacer:

```sql
insert into public.admin_users (user_id) values ('UUID-COPIADO-AQUI');
```

Para dar acceso a otra profesional, repite los pasos 3 y 4. Para quitarlo:
`delete from public.admin_users where user_id = '...';`

### 5. Obtener la Project URL
Ve a **Project Settings → Data API** (o al botón **Connect** de la barra superior). La URL tiene la forma `https://xxxxxxxx.supabase.co`.

### 6. Obtener la anon / public key
Ve a **Project Settings → API Keys** y copia la clave **`anon` `public`** (pestaña *Legacy API keys*) o la **publishable key** (`sb_publishable_...`). Cualquiera de las dos sirve.

> ⚠️ **No** copies la `service_role` ni la `secret` key.

### 7. Pegarlas en el frontend
En `index.html`, al comienzo del segundo bloque `<script>` (busca `CONFIGURACIÓN DE SUPABASE`):

```javascript
const SUPABASE_URL='https://xxxxxxxx.supabase.co';
const SUPABASE_ANON_KEY='eyJhbGciOi...';   // o 'sb_publishable_...'
```

### 8. Subir los cambios a GitHub
```bash
git add index.html
git commit -m "Configurar Supabase"
git push origin main
```
O edita `index.html` directamente en github.com con el ícono del lápiz y pulsa **Commit changes**.

### 9. Verificar GitHub Pages
En el repositorio ve a **Settings → Pages** y confirma que la fuente es `main` / `root`. Espera 1–2 minutos y abre la URL publicada, por ejemplo `https://legionstudio-star.github.io/NUTRICIONISTA/`. Recarga con Ctrl+F5 para evitar la caché.

### 10. Probar una respuesta desde una ventana de incógnito
1. Abre la página en incógnito (o desde el celular) y completa una encuesta.
2. Al finalizar debe aparecer **"Respuesta guardada correctamente"**.
3. En Supabase, en **Table Editor → survey_responses**, debe aparecer la fila.

### 11. Probar el login del panel
1. Pulsa **📊 Panel nutricionista** e inicia sesión con el correo y la contraseña del paso 3.
2. Deben verse las respuestas. Cambia de encuesta con el selector **Encuesta**.
3. Con el panel abierto, responde una encuesta desde otro dispositivo: el panel se actualiza solo (indicador **"En vivo"**).
4. **Cerrar sesión** debe llevarte al inicio. Al volver a pulsar el panel, debe pedirte contraseña de nuevo.

### 12. Verificar que un anónimo NO puede leer la tabla
Desde una terminal (reemplaza URL y KEY):

```bash
curl "https://xxxxxxxx.supabase.co/rest/v1/survey_responses?select=*" \
  -H "apikey: TU_ANON_KEY" -H "Authorization: Bearer TU_ANON_KEY"
```

La respuesta esperada es un error `42501` (*permission denied for table survey_responses*). **Nunca** debe devolver respuestas.

También puedes probarlo desde la consola del navegador en la página publicada:

```javascript
await sb.from('survey_responses').select('*')   // → error 42501
```

---

## Funcionalidades del panel

- Selector de encuesta (satisfacción / concertación). En satisfacción hay además un filtro por **frecuencia de consumo**.
- Filtros **Desde / Hasta**, calculados con la fecha local del navegador sobre `created_at`.
- Métricas, porcentajes, gráficos, distribuciones, comentarios abiertos, hallazgos automáticos e informe ejecutivo.
- **CSV**: exporta solo la encuesta y los filtros seleccionados.
- **Backup**: JSON con todas las respuestas cargadas.
- **Informe PDF**: impresión del panel (*Guardar como PDF*).
- **↻ Actualizar** y actualización **en vivo** con Supabase Realtime. La suscripción se abre al entrar al panel y se cierra al salir o al cerrar sesión.
- **Borrar encuesta**: elimina en Supabase las respuestas de la encuesta seleccionada. Pide escribir `BORRAR` para confirmar.
- **Migrar respuestas locales a Supabase**: aparece solo si el navegador tiene datos de la versión anterior (`encuestaMenuRespuestasV3` / `encuestaMenuRespuestasV2`).
  - Las sube con su fecha original y usa `legacy_id` para no duplicarlas.
  - Verifica que todas quedaron en la base y **solo entonces** las borra del navegador.
  - Los registros de demostración (`DEMO-...`) no se migran.
  - Hay que abrir el panel **en el mismo navegador y equipo** donde se usaba la versión anterior.

### Envío de encuestas
- Antes de enviar se validan todas las preguntas.
- El botón muestra "Guardando…" y se bloquea, lo que evita el doble envío. Además, `legacy_id` impide duplicados si se reintenta.
- Solo se muestra "guardada correctamente" cuando Supabase confirma el INSERT.
- Si falla, se muestra el error con dos opciones:
  - **Reintentar envío**.
  - **Guardar en este dispositivo y enviar después**: la respuesta queda en una cola local (`encuestaMenuPendientesSupabase`) y se reenvía automáticamente al volver a abrir la página o al recuperar la conexión.

---

## Solución de problemas

| Síntoma | Causa probable / solución |
|---|---|
| Banner "La plataforma aún no está conectada a la base de datos" | Faltan `SUPABASE_URL` / `SUPABASE_ANON_KEY` en `index.html`, o siguen los placeholders. |
| "No fue posible conectar con el servidor" al enviar | Proyecto de Supabase **pausado** (los proyectos gratuitos se pausan tras ~7 días sin actividad; reactívalo con *Resume project*), sin internet, o URL mal escrita. |
| Error al enviar con código `42P01` en la consola | No se ejecutó `supabase_schema.sql`. |
| Error `42501` al **enviar** | Se modificaron las políticas o permisos; vuelve a ejecutar `supabase_schema.sql`. |
| Login: "Correo o contraseña incorrectos" | Revisa las credenciales, o restablece la contraseña en *Authentication → Users → ⋯ → Send password recovery*. |
| Login: "El correo aún no ha sido confirmado" | En *Authentication → Users*, confirma el usuario, o créalo de nuevo con **Auto Confirm User**. |
| Login: "Esta cuenta no está autorizada" | El usuario existe pero no está en `admin_users` (paso 4). |
| El panel carga pero aparece vacío | No hay respuestas todavía, o los filtros de fecha excluyen todo (pulsa **Limpiar filtros**). |
| El indicador dice "Sin actualización en vivo" | Realtime no está activo para la tabla. Vuelve a ejecutar el bloque 5 del SQL, o actívalo en *Database → Publications → supabase_realtime*. El botón ↻ Actualizar sigue funcionando. |
| "Tu sesión expiró" | El token caducó o se cerró sesión en otra pestaña; inicia sesión otra vez. |
| Cambios que no se ven en GitHub Pages | Espera 1–2 minutos y recarga con Ctrl+F5. |

## Archivos

- `index.html`: aplicación completa (encuestas y panel).
- `supabase_schema.sql`: tablas, índices, RLS, políticas y Realtime.
- `README.md`: este documento.
