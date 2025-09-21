from transformers import pipeline

gen = pipeline("text2text-generation", model="google/flan-t5-small")

pergunta = "Qual é a capital do Brasil?"
resp = gen(pergunta, max_new_tokens=50, do_sample=False)[0]["generated_text"]

print("Pergunta:", pergunta)
print("Resposta:", resp)
