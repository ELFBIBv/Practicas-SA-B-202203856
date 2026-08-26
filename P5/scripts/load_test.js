import http from 'k6/http';
import { check, sleep } from 'k6';

// Configuración de la prueba de carga:
// Simularemos un incremento progresivo de concurrencia para ver cómo 
// el HPA (Horizontal Pod Autoscaler) escala automáticamente los pods.
export let options = {
    stages: [
        { duration: '30s', target: 20 }, // Rampa de subida a 20 usuarios virtuales (VUs)
        { duration: '1m', target: 50 },  // Rampa de subida a 50 VUs (aquí debería dispararse el HPA)
        { duration: '30s', target: 100 }, // Rampa a 100 VUs para máximo estrés
        { duration: '1m', target: 100 },  // Mantener carga máxima por 1 minuto
        { duration: '30s', target: 0 },   // Rampa de bajada a 0
    ],
    thresholds: {
        http_req_duration: ['p(95)<500'], // El 95% de las peticiones deben ser menores a 500ms
        http_req_failed: ['rate<0.01'],   // Menos del 1% de errores
    },
};

export default function () {
    // Reemplaza localhost con la IP de tu Ingress de Minikube (minikube ip) o dominio configurado.
    // k6 run -e TARGET_URL=http://tu-ip scripts/load_test.js
    let targetURL = __ENV.TARGET_URL || 'http://localhost'; 

    // Aquí enviamos una carga al catálogo como ejemplo síncrono. 
    // También se podría cargar el /graphql de orders para estresar el productor de NATS.
    let query = `
      query {
        products {
          id
          name
          price
        }
      }
    `;

    let payload = JSON.stringify({
      query: query,
    });

    let params = {
      headers: {
        'Content-Type': 'application/json',
      },
    };

    let res = http.post(`${targetURL}/graphql`, payload, params);

    check(res, {
        'status es 200': (r) => r.status === 200,
        'tiempo de respuesta < 2000ms': (r) => r.timings.duration < 2000,
    });

    // Un pequeño sleep para simular el comportamiento de un usuario real
    sleep(1);
}
