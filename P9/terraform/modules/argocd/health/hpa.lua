-- Como el health integrado, salvo que la falta TRANSITORIA de metricas (Pods
-- recien creados) es Progressing y no Degraded. Los errores de configuracion
-- siguen Degraded. Sin esto, un HPA recien creado que aun no tiene metricas
-- hace fallar la ola 1 de sa-platform por un ciclo de backoff evitable.
-- Fuente: P9/docs/diseno-sync-waves.md §3.6.
local hs = { status = "Progressing", message = "Esperando metricas del HPA" }
if obj.status == nil or obj.status.conditions == nil then
  return hs
end
for _, c in ipairs(obj.status.conditions) do
  if (c.type == "AbleToScale" and (c.reason == "FailedGetScale" or c.reason == "FailedUpdateScale"))
     or (c.type == "ScalingActive" and c.reason == "InvalidSelector") then
    hs.status = "Degraded"
    hs.message = c.message or c.reason
    return hs
  end
end
for _, c in ipairs(obj.status.conditions) do
  if c.type == "ScalingActive" and c.status == "True" then
    hs.status = "Healthy"
    hs.message = c.message or ""
    return hs
  end
end
return hs
