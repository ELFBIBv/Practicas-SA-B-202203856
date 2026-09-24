{{- define "mongodb.fullname" -}}
{{- printf "%s-mongodb" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "mongodb.secretName" -}}
{{- default (include "mongodb.fullname" .) .Values.auth.existingSecret -}}
{{- end }}
