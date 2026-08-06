import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import axios from 'axios';

export const Dashboard = () => {
  const navigate = useNavigate();
  const [data, setData] = useState<any>(null);
  const [error, setError] = useState('');
  const [route, setRoute] = useState('/ruta1');

  useEffect(() => {
    fetchData();
  }, [route]);

  const fetchData = async () => {
    try {
      const response = await axios.get(`http://localhost:3000${route}`, {
        withCredentials: true
      });
      setData(response.data);
      setError('');
    } catch (err: any) {
      setError(err.response?.data?.message || 'Acceso denegado');
      setData(null);
    }
  };

  const handleLogout = () => {
    // Basic logout logic (could call backend to clear cookie, but for now just clear client state if any)
    navigate('/login');
  };

  return (
    <div className="dashboard">
      <h1>Panel de Control</h1>
      
      <div className="glass-container">
        <div style={{ display: 'flex', gap: '1rem', marginBottom: '2rem' }}>
          <button 
            className={route === '/ruta1' ? 'btn-primary' : 'btn-secondary'} 
            onClick={() => setRoute('/ruta1')}
            style={{ marginTop: 0 }}
          >
            Probar Ruta 1
          </button>
          <button 
            className={route === '/ruta2' ? 'btn-primary' : 'btn-secondary'} 
            onClick={() => setRoute('/ruta2')}
            style={{ marginTop: 0 }}
          >
            Probar Ruta 2
          </button>
        </div>

        <div className="dashboard-card">
          {error && <div className="error-message">{error}</div>}
          {data && (
            <div className="success-message">
              <strong>Éxito:</strong> {data.message}
            </div>
          )}
        </div>

        <button className="btn-secondary" onClick={handleLogout} style={{ marginTop: '2rem' }}>
          Cerrar Sesión
        </button>
      </div>
    </div>
  );
};
