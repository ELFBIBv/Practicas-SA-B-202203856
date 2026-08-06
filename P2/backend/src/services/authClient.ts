import axios from 'axios';
import axiosRetry from 'axios-retry';

const AUTH_SERVICE_URL = process.env.AUTH_SERVICE_URL || 'http://localhost:4000';

const client = axios.create({
    baseURL: AUTH_SERVICE_URL,
});

const RETRY_COUNT = parseInt(process.env.RETRY_COUNT || '3');
const RETRY_BACKOFF_MS = parseInt(process.env.RETRY_BACKOFF_MS || '1000');

// Configure retry loop with backoff
axiosRetry(client, {
    retries: RETRY_COUNT, // Number of max retries
    retryDelay: (retryCount) => {
        // Exponential backoff or configurable backoff base
        console.log(`Retry attempt: ${retryCount}`);
        return retryCount * RETRY_BACKOFF_MS; // Simple linear backoff or could be exponential `Math.pow(2, retryCount) * RETRY_BACKOFF_MS`
    },
    retryCondition: (error) => {
        // Retry on network errors or 5xx status codes
        return axiosRetry.isNetworkOrIdempotentRequestError(error) || error.response?.status === 500 || error.code === 'ECONNREFUSED';
    }
});

export const checkAuthorization = async (rol: string, route: string): Promise<boolean> => {
    try {
        const response = await client.post('/authorize', { rol, route });
        return response.data.allowed;
    } catch (error: any) {
        if (error.response && error.response.status === 403) {
            return false;
        }
        console.error('Error communicating with Auth Microservice:', error.message);
        throw new Error('Authorization service unavailable after retries');
    }
};
