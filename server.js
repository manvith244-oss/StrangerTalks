const express = require('express');
const app = express();

const TARGET = 'https://strangertalks-phoenix.onrender.com';

app.use((req, res) => {
  res.redirect(302, TARGET);
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, '0.0.0.0', () => {
  console.log(`StrangerTalks redirect bridge listening on port ${PORT}`);
});
