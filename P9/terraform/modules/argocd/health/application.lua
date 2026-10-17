-- Health de una Application hija, visto por la raiz. No basta con copiar
-- status.health: los hooks y los recursos Missing no cuentan ahi (H5), asi que
-- una hija con su Job de restauracion en curso ya se ve Healthy.
-- Fuente: P9/docs/diseno-sync-waves.md §3.1.
local hs = { status = "Progressing", message = "Esperando la primera reconciliacion" }
if obj.status == nil then
  return hs
end
local op = obj.status.operationState
if op ~= nil then
  -- Mientras reintenta con backoff, la fase sigue en Running.
  if op.phase == "Running" or op.phase == "Terminating" then
    hs.message = "Sync en curso: " .. (op.message or "")
    return hs
  end
  if op.phase == "Failed" or op.phase == "Error" then
    hs.status = "Degraded"
    hs.message = "Ultimo sync fallido: " .. (op.message or "")
    return hs
  end
end
local sync = "Unknown"
if obj.status.sync ~= nil and obj.status.sync.status ~= nil then
  sync = obj.status.sync.status
end
if sync ~= "Synced" then
  -- Recien creada (antes de su primer auto-sync) o con cambios sin aplicar.
  hs.message = "Hija en " .. sync .. " sin operacion en curso"
  return hs
end
if obj.status.health ~= nil and obj.status.health.status ~= nil then
  hs.status = obj.status.health.status
  hs.message = obj.status.health.message or ""
end
return hs
