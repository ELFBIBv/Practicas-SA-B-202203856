import axios from 'axios';
import axiosRetry from 'axios-retry';

const AUTH_SERVICE_URL = process.env.AUTH_SERVICE_URL || 'http://localhost:4000';

const client = axios.create({
    baseURL: AUTH_SERVICE_URL,
});

// Configure retry loop with backoff
axiosRetry(client, {
    retries: 3, // Number of max retries
    retryDelay: (retryCount) => {
        // Exponential backoff
        console.log(`Retry attempt: ${retryCount}`);
        return axiosRetry.exponentialDelay(retryCount);
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
