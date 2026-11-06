// Derived from context-21b8348e.json. Preserve the original Russian prompt,
// hosted web actions, reasoning summaries, and cited final answer. Only model
// IDs and opaque encrypted reasoning are replaced with fixture identities.
// A cold-resumed turn exposes the complete streamed response to comparison.
const fermentedBeetrootCase = <String, dynamic>{
  "id": "fermented-beetroot",
  "workflow": "hosted-web",
  "prompt": "польза квашеной свеклы? посмотри в интернете",
  "messages": [
    "польза квашеной свеклы? посмотри в интернете",
    "Сохрани предыдущий ответ с источниками и ответь READY."
  ],
  "request_user_input": true,
  "retain_model_items": true,
  "indexless_stream": true,
  "files": <String, Object?>{},
  "contains": <Object?>[],
  "absent": <Object?>[],
  "responses": [
    [
      {
        "type": "reasoning",
        "summary": <Object?>[],
        "content": null,
        "encrypted_content": "fermented-beetroot-reasoning-1"
      },
      {
        "type": "message",
        "status": "completed",
        "phase": "commentary",
        "role": "assistant",
        "content": [
          {
            "type": "output_text",
            "annotations": <Object?>[],
            "logprobs": <Object?>[],
            "text": "Посмотрю, что известно о пользе именно квашеной свёклы и насколько эти выводы подтверждены исследованиями."
          }
        ]
      },
      {
        "type": "web_search_call",
        "status": "completed",
        "action": {
          "type": "search",
          "queries": [
            "fermented beetroot clinical trial health effects beetroot juice lacto fermented randomized trial blood pressure",
            "fermented beetroot human clinical trial gut microbiota lactobacillus evidence systematic review",
            "beetroot nitrate blood pressure systematic review randomized trials hypertension meta-analysis 2024",
            "NIH fermented foods live microbes probiotics not all fermented foods sodium beetroot oxalate"
          ],
          "query": "fermented beetroot clinical trial health effects beetroot juice lacto fermented randomized trial blood pressure"
        }
      },
      {
        "type": "reasoning",
        "summary": [
          {
            "type": "summary_text",
            "text": "**Opening primary source**"
          },
          {
            "type": "summary_text",
            "text": "**Checking beet nutrient data**"
          }
        ],
        "content": null,
        "encrypted_content": "fermented-beetroot-reasoning-2"
      },
      {
        "type": "web_search_call",
        "status": "completed",
        "action": {
          "type": "search",
          "queries": [
            "site:pmc.ncbi.nlm.nih.gov fermented beetroot juice trial healthy volunteers 2023 betalains anti inflammatory",
            "site:niddk.nih.gov kidney stones oxalate beets avoid beetroot",
            "site:who.int sodium adults less than 2000 mg 5 grams salt per day 2025",
            "beets nutrition fiber folate potassium US department agriculture 100 grams beetroot raw fooddata central",
            "site:pubmed.ncbi.nlm.nih.gov fermented foods diet randomized trial microbiome diversity inflammation Stanford 2021 fermented"
          ],
          "query": "site:pmc.ncbi.nlm.nih.gov fermented beetroot juice trial healthy volunteers 2023 betalains anti inflammatory"
        }
      },
      {
        "type": "reasoning",
        "summary": [
          {
            "type": "summary_text",
            "text": "**Opening IJMS article**"
          }
        ],
        "content": null,
        "encrypted_content": "fermented-beetroot-reasoning-3"
      },
      {
        "type": "web_search_call",
        "status": "completed",
        "action": {
          "type": "open_page",
          "url": "https://pmc.ncbi.nlm.nih.gov/articles/PMC13664913/"
        }
      },
      {
        "type": "reasoning",
        "summary": [
          {
            "type": "summary_text",
            "text": "**Checking article date**"
          }
        ],
        "content": null,
        "encrypted_content": "fermented-beetroot-reasoning-4"
      },
      {
        "type": "web_search_call",
        "status": "completed",
        "action": {
          "type": "search",
          "queries": [
            "site:kidney.org beets oxalate beetroot kidney stones",
            "site:who.int sodium reduction adults less than 5g salt per day 2025",
            "site:extension.umn.edu fermenting vegetables mold discard spoilage",
            "site:nih.gov beet root oxalate kidney stones high oxalate"
          ],
          "query": "site:kidney.org beets oxalate beetroot kidney stones"
        }
      },
      {
        "type": "reasoning",
        "summary": [
          {
            "type": "summary_text",
            "text": "**Reviewing fermented-beet claims**"
          }
        ],
        "content": null,
        "encrypted_content": "fermented-beetroot-reasoning-5"
      },
      {
        "type": "reasoning",
        "summary": [
          {
            "type": "summary_text",
            "text": "**Проверяю данные о ферментированной свёкле**"
          }
        ],
        "content": null,
        "encrypted_content": "fermented-beetroot-reasoning-6"
      },
      {
        "type": "web_search_call",
        "status": "completed",
        "action": {
          "type": "find_in_page",
          "pattern": "mold",
          "url": "https://extension.umn.edu/som/node/172346"
        }
      },
      {
        "type": "reasoning",
        "summary": [
          {
            "type": "summary_text",
            "text": "**Проверяю РКИ о ферментированных продуктах**"
          }
        ],
        "content": null,
        "encrypted_content": "fermented-beetroot-reasoning-7"
      },
      {
        "type": "message",
        "status": "completed",
        "phase": "final_answer",
        "role": "assistant",
        "content": [
          {
            "type": "output_text",
            "annotations": [
              {
                "type": "url_citation",
                "end_index": 348,
                "start_index": 272,
                "title": "Fresh and Fermented Beetroot: From Microbial Biotransformation to Nitrate–Nitrite–NO Signalling, Redox Homeostasis and Microbiome Interactions - PMC",
                "url": "https://pmc.ncbi.nlm.nih.gov/articles/PMC13664913/"
              },
              {
                "type": "url_citation",
                "end_index": 644,
                "start_index": 563,
                "title": "",
                "url": "https://www.growables.org/informationVeg/documents/BeetRaw.pdf"
              },
              {
                "type": "url_citation",
                "end_index": 1066,
                "start_index": 996,
                "title": "Gut-microbiota-targeted diets modulate human immune status - PubMed",
                "url": "https://pubmed.ncbi.nlm.nih.gov/34256014/"
              },
              {
                "type": "url_citation",
                "end_index": 1372,
                "start_index": 1302,
                "title": "Effects of beetroot juice on blood pressure in hypertension according to European Society of Hypertension Guidelines: A systematic review and meta-analysis - PubMed",
                "url": "https://pubmed.ncbi.nlm.nih.gov/39069465/"
              },
              {
                "type": "url_citation",
                "end_index": 1797,
                "start_index": 1678,
                "title": "Sodium reduction",
                "url": "https://www.who.int/news-room/fact-sheets/detail/sodium-reduction?linkId=100000202663036&utm_source=openai"
              }
            ],
            "logprobs": <Object?>[],
            "text": "Квашеная свёкла может быть полезной частью рациона: она даёт клетчатку и другие вещества из свёклы, а если не пастеризована — ещё и живые молочнокислые бактерии. Но исследований именно её влияния на здоровье людей пока мало, поэтому приписывать ей лечебные свойства рано. ([pmc.ncbi.nlm.nih.gov](https://pmc.ncbi.nlm.nih.gov/articles/PMC13664913/))\n\nЧто известно о возможной пользе:\n\n- **Клетчатка и питательные вещества.** В свёкле есть клетчатка, фолат и калий. Для ориентира: в 100 г сырой свёклы около 2,8 г клетчатки; после квашения состав может измениться. ([growables.org](https://www.growables.org/informationVeg/documents/BeetRaw.pdf))\n- **Живые бактерии.** Непастеризованная квашеная свёкла может их содержать. В небольшом исследовании рацион с разными ферментированными продуктами увеличивал разнообразие кишечной микробиоты, но этот результат нельзя автоматически перенести на конкретную банку свёклы. Живые бактерии также не обязательно являются пробиотиками с доказанным действием. ([pubmed.ncbi.nlm.nih.gov](https://pubmed.ncbi.nlm.nih.gov/34256014/))\n- **Влияние на давление.** Свекольный сок, богатый нитратами, в ряде исследований немного снижал верхнее давление у людей с гипертонией. Достоверность доказательств невысокая, а для квашеной свёклы такой эффект отдельно не установлен. ([pubmed.ncbi.nlm.nih.gov](https://pubmed.ncbi.nlm.nih.gov/39069465/))\n\n**На что обратить внимание:** в квашеной свёкле может быть много соли. Это особенно важно при гипертонии и ограничении соли: ВОЗ рекомендует взрослым менее 5 г соли в сутки из *всех* продуктов. Если у тебя были оксалатные камни в почках, количество свёклы стоит обсудить с врачом: она содержит оксалаты. ([who.int](https://www.who.int/news-room/fact-sheets/detail/sodium-reduction?linkId=100000202663036&utm_source=openai))\n\nМожно начать с пары столовых ложек вместе с едой и посмотреть, как переносится. Установленной «лечебной дозы» нет. Если покупаешь свёклу ради живых культур, ищи на упаковке указание, что она **непастеризованная** или содержит живые культуры."
          }
        ]
      }
    ]
  ],
  "resume_responses": [
    [
      {
        "type": "message",
        "role": "assistant",
        "content": [
          {
            "type": "output_text",
            "text": "READY",
            "annotations": <Object?>[]
          }
        ]
      }
    ]
  ]
};
