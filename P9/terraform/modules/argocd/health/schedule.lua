-- Backport del health de ArgoCD v3.6 (no existe en v3.5.3, la version instalada).
-- Sin este Lua, un cron invalido deja el Schedule en FailedValidation en
-- silencio: nunca mas hay respaldos y el RPO real se vuelve infinito sin que
-- nada lo muestre.
-- Fuente: P9/docs/diseno-sync-waves.md §3.5.
local hs = { status = "Progressing", message = "Esperando que Velero valide el Schedule" }
if obj.status ~= nil and obj.status.phase ~= nil then
  if obj.status.phase == "Enabled" then
    hs.status = "Healthy"
    hs.message = "Schedule habilitado"
  elseif obj.status.phase == "FailedValidation" then
    hs.status = "Degraded"
    hs.message = "Schedule con validacion fallida"
  else
    hs.message = obj.status.phase
  end
end
return hs
