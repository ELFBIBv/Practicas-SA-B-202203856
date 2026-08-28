import http from 'k6/http';
import { check, sleep } from 'k6';

// Configuración de la prueba de carga:
// Simularemos un incremento progresivo de concurrencia para ver cómo 
// el HPA (Horizontal Pod Autoscaler) escala automáticamente los pods.
export let options = {
    stages: [
        { duration: '30s', target: 50 }, // Rampa de subida a 50 usuarios virtuales (VUs)
        { duration: '1m', target: 150 },  // Rampa de subida a 150 VUs (aquí debería dispararse el HPA)
        { duration: '30s', target: 300 }, // Rampa a 300 VUs para máximo estrés
        { duration: '1m', target: 300 },  // Mantener carga máxima por 1 minuto
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
    let targetURL = __ENV.TARGET_URL || 'http://localhost:8080'; 

    // --- 1. Catálogo ---
    let catalogQuery = `
      query {
        products {
          id
          name
          price
        }
      }
    `;
    let params = {
      headers: {
        'Content-Type': 'application/json',
      },
    };
    let resCatalog = http.post(`${targetURL}/api/catalog/graphql`, JSON.stringify({ query: catalogQuery }), params);

    // --- 2. Órdenes ---
    let ordersQuery = `
      query {
        orders {
          id
          total
          status
        }
      }
    `;
    let resOrders = http.post(`${targetURL}/api/orders/graphql`, JSON.stringify({ query: ordersQuery }), params);

    // --- 3. Autenticación ---
    // Hacemos una petición de login para estresar la base de datos y la función de cifrado de contraseñas
    let resAuth = http.post(`${targetURL}/api/auth/login`, JSON.stringify({ carnet: "k6-load-test", password: "fake" }), params);

    // Validamos los resultados
    check(resCatalog, {
        'Catálogo status es 200': (r) => r.status === 200,
    });
    check(resOrders, {
        'Órdenes status es 200': (r) => r.status === 200,
    });
    check(resAuth, {
        'Auth status es procesado (401 o 200)': (r) => r.status === 200 || r.status === 401,
    });

    // Un pequeño sleep para simular el comportamiento de un usuario real
    sleep(0.1);
}
