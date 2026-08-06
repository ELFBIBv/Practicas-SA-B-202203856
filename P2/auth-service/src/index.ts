import express from 'express';
import cors from 'cors';
import dotenv from 'dotenv';

dotenv.config();

const app = express();
const PORT = process.env.PORT || 4000;

app.use(cors());
app.use(express.json());

app.post('/authorize', (req, res) => {
    // This endpoint will be implemented next
    res.status(200).json({ message: "Authorization logic will go here" });
});

app.listen(PORT, () => {
    console.log(`Authorization microservice running on http://localhost:${PORT}`);
});
