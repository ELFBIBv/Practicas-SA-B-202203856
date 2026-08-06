import { useState } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import axios from 'axios';

export const Register = () => {
  const navigate = useNavigate();
  const [formData, setFormData] = useState({ carnet: '', nombres: '', apellidos: '', password: '' });
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setSuccess('');
    setLoading(true);

    try {
      await axios.post('http://localhost:3000/register', formData);
      setSuccess('Usuario registrado con éxito. Redirigiendo...');
      setTimeout(() => navigate('/login'), 2000);
    } catch (err: any) {
      setError(err.response?.data?.message || 'Error al registrar usuario');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="glass-container">
      <h1>Registro</h1>
      {error && <div className="error-message">{error}</div>}
      {success && <div className="success-message">{success}</div>}
      <form onSubmit={handleSubmit}>
        <div className="form-group">
          <label>Carnet</label>
          <input
            type="text"
            required
            value={formData.carnet}
            onChange={(e) => setFormData({ ...formData, carnet: e.target.value })}
          />
        </div>
        <div className="form-group">
          <label>Nombres</label>
          <input
            type="text"
            required
            value={formData.nombres}
            onChange={(e) => setFormData({ ...formData, nombres: e.target.value })}
          />
        </div>
        <div className="form-group">
          <label>Apellidos</label>
          <input
            type="text"
            required
            value={formData.apellidos}
            onChange={(e) => setFormData({ ...formData, apellidos: e.target.value })}
          />
        </div>
        <div className="form-group">
          <label>Contraseña</label>
          <input
            type="password"
            required
            value={formData.password}
            onChange={(e) => setFormData({ ...formData, password: e.target.value })}
          />
        </div>
        <button type="submit" className="btn-primary" disabled={loading}>
          {loading ? 'Registrando...' : 'Registrarse'}
        </button>
      </form>
      <Link to="/login" className="link-text">
        ¿Ya tienes cuenta? Inicia sesión
      </Link>
    </div>
  );
};
