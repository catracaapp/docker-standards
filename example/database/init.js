// Roda uma vez quando o volume do Mongo é criado (não em subidas subsequentes).
// Cria o documento "global" do contador, começando em 0.
db = db.getSiblingDB('demo');
db.counters.updateOne(
  { _id: 'global' },
  { $setOnInsert: { value: 0 } },
  { upsert: true }
);
print('seed: counters.global inicializado');
