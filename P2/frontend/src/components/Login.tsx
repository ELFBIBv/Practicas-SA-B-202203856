import { useState } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import axios from 'axios';

export const Login = () => {
  const navigate = useNavigate();
  const [formData, setFormData] = useState({ carnet: '', password: '' });
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setLoading(true);

    try {
      await axios.post('http://localhost:3000/login', formData, {
        withCredentials: true
      });
      navigate('/dashboard');
    } catch (err: any) {
      setError(err.response?.data?.message || 'Error al iniciar sesión');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="glass-container">
      <h1>Iniciar Sesión</h1>
      {error && <div className="error-message">{error}</div>}
      <form onSubmit={handleSubmit}>
        <div className="form-group">
          <label>Carnet</label>
          <input
            type="text"
            required
            value={formData.carnet}
            onChange={(e) => setFormData({ ...formData, carnet: e.target.value })}
            placeholder="Ej: 202203856"
          />
        </div>
        <div className="form-group">
          <label>Contraseña</label>
          <input
            type="password"
            required
            value={formData.password}
            onChange={(e) => setFormData({ ...formData, password: e.target.value })}
            placeholder="••••••••"
          />
        </div>
        <button type="submit" className="btn-primary" disabled={loading}>
          {loading ? 'Ingresando...' : 'Ingresar'}
        </button>
      </form>
      <Link to="/register" className="link-text">
        ¿No tienes cuenta? Regístrate aquí
      </Link>
    </div>
  );
};
