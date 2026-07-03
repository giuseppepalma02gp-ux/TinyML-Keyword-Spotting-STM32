/* USER CODE BEGIN Header */
/**
  ******************************************************************************
  * @file           : main.c
  * @brief          : Main program body
  ******************************************************************************
  * @attention
  *
  * Copyright (c) 2026 STMicroelectronics.
  * All rights reserved.
  *
  * This software is licensed under terms that can be found in the LICENSE file
  * in the root directory of this software component.
  * If no LICENSE file comes with this software, it is provided AS-IS.
  *
  ******************************************************************************
  */
/* USER CODE END Header */
/* Includes ------------------------------------------------------------------*/
#include "main.h"

/* Private includes ----------------------------------------------------------*/
/* USER CODE BEGIN Includes */
#include "edge-impulse-sdk/classifier/ei_run_classifier.h"
#include <stdio.h> // Necessario per usare snprintf e sscanf
#include <string.h>
/* USER CODE END Includes */

/* Private typedef -----------------------------------------------------------*/
/* USER CODE BEGIN PTD */
typedef enum {
    STATE_WAIT_HEADER = 0, //stato iniziale
    STATE_RECEIVE_AUDIO, //stato in cui riceve i byte audio
    STATE_RUN_INFERENCE, //stato in cui viene eseguita run_classifier
    STATE_SEND_RESULT //stato finale
} uart_state_t;
/* USER CODE END PTD */

/* Private define ------------------------------------------------------------*/
/* USER CODE BEGIN PD */
#define CLASSIFICATION_THRESHOLD  0.70f  //Soglia minima per accettare una classificazione
#define UNKNOWN_LABEL             "unknown" //Costante per la label della classe sconosciuta.

/* USER CODE END PD */

/* Private macro -------------------------------------------------------------*/
/* USER CODE BEGIN PM */

/* USER CODE END PM */

/* Private variables ---------------------------------------------------------*/
UART_HandleTypeDef huart2; //necessario per tutte le chiamate HAL UART
DMA_HandleTypeDef hdma_usart2_rx;

/* USER CODE BEGIN PV */
// Buffer audio: 16000 campioni int16 = 32000 byte
#define AUDIO_BUFFER_BYTES   (EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE * 2)
#define HEADER_BUFFER_SIZE   64 //Lunghezza massima dell’header testuale

uint8_t rx_buffer[AUDIO_BUFFER_BYTES]; //Buffer che contiene l’audio ricevuto via UART
uint32_t rx_index = 0; //Indice di scrittura del buffer audio.

char header_buffer[HEADER_BUFFER_SIZE]; //Buffer per ricevere la riga di header ASCII.
uint32_t header_index = 0; //Indice di scrittura per l’header.

uint32_t expected_samples = 0; //inizializzazione campioni attesi payload
uint32_t expected_bytes = 0; //inizializzazione bytes attesi

uart_state_t uart_state = STATE_WAIT_HEADER; //mette la macchina a stati in stato d'attesa

// --- AGGIUNGI QUESTA RIGA QUI ---
volatile uint8_t dma_rx_complete = 0;
/* USER CODE END PV */

/* Private function prototypes -----------------------------------------------*/
void SystemClock_Config(void);
static void MX_GPIO_Init(void);
static void MX_DMA_Init(void);
static void MX_USART2_UART_Init(void);
/* USER CODE BEGIN PFP */
void reset_uart_session(void); //Prototipo della funzione che resetta stato e buffer UART.
int parse_header(char *header, uint32_t *samples, uint32_t *bytes);
void send_text(const char *text); //per mandare le stringhe a matlab
/* USER CODE END PFP */
/* Private user code ---------------------------------------------------------*/
/* USER CODE BEGIN 0 */

// Funzione "ponte" richiesta da Edge Impulse per pescare i dati audio
/*Questo blocco prende i byte audio ricevuti via UART,
 *  li ricostruisce come campioni int16_t, e li restituisce in formato float a Edge Impulse.
 *  La documentazione Edge Impulse spiega che get_data deve riempire un buffer di float,
 *  e che puoi convertire da int16_t con helper o con una conversione equivalente manuale.
 */
int raw_feature_get_data(size_t offset, size_t length, float *out_ptr) //offset e length dicono quali campioni servono in quel momento; out_ptr è il buffer di output float
{
    if ((offset + length) > EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE) //Controlla che la richiesta non esca oltre la dimensione del frame atteso
    {
        return -1;
    }

    if (((offset + length) * 2) > expected_bytes) //Secondo controllo di sicurezza sul buffer bytes. Utile, perché il buffer audio è in byte e ogni campione occupa 2 byte
    {
        return -1;
    }

    for (size_t i = 0; i < length; i++)
    {
        size_t sample_index = offset + i; //Calcola l’indice del campione corrente
        size_t byte_index = sample_index * 2; //Converte l’indice del campione nell’indice dei byte
        int16_t sample = (int16_t)( //Ricostruisce il campione signed 16-bit dai due byte
            ((uint16_t)rx_buffer[byte_index]) |
            ((uint16_t)rx_buffer[byte_index + 1] << 8)
        );

        out_ptr[i] = (float)sample; //Converte il campione in float e lo scrive nel buffer di outpu
    }

    return 0;
}
/* USER CODE END 0 */

/**
  * @brief  The application entry point.
  * @retval int
  */
int main(void)
{

  /* USER CODE BEGIN 1 */

  /* USER CODE END 1 */

  /* MCU Configuration--------------------------------------------------------*/

  /* Reset of all peripherals, Initializes the Flash interface and the Systick. */
  HAL_Init();

  /* USER CODE BEGIN Init */

  /* USER CODE END Init */

  /* Configure the system clock */
  SystemClock_Config();

  /* USER CODE BEGIN SysInit */

  /* USER CODE END SysInit */

  /* Initialize all configured peripherals */
  MX_GPIO_Init();
  MX_DMA_Init();
  MX_USART2_UART_Init();
  /* USER CODE BEGIN 2 */

  /* USER CODE END 2 */

  /* Infinite loop */
  /* USER CODE BEGIN WHILE */
  while (1)
  {
      uint8_t rx_byte; //Variabile temporanea per il byte ricevuto

      switch (uart_state) //Seleziona il comportamento in base allo stato corrente
      {
      case STATE_WAIT_HEADER: //stato iniziale
                    if (HAL_UART_Receive(&huart2, &rx_byte, 1, 10) == HAL_OK) //L'header lo riceviamo ancora in polling (è testo breve)
                    {
                        if (rx_byte == '\r')
                        {
                            break;
                        }

                        if (rx_byte == '\n')
                        {
                            header_buffer[header_index] = '\0';

                            if (parse_header(header_buffer, &expected_samples, &expected_bytes))
                            {
                                if ((expected_samples == EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE) &&
                                    (expected_bytes == (expected_samples * 2)) &&
                                    (expected_bytes <= AUDIO_BUFFER_BYTES))
                                {
                                    rx_index = 0;
                                    header_index = 0;
                                    memset(header_buffer, 0, sizeof(header_buffer));

                                    // ----- MODIFICA DMA QUI -----
                                    dma_rx_complete = 0; // Azzera il flag prima di partire
                                    uart_state = STATE_RECEIVE_AUDIO;
                                    send_text("HEADER_OK\n");

                                    // LANCIA IL DMA! Da questo momento l'hardware lavora in background
                                    HAL_UART_Receive_DMA(&huart2, rx_buffer, expected_bytes);
                                    // ----------------------------
                                }
                                else
                                {
                                    char dbg[128];
                                    snprintf(dbg, sizeof(dbg),
                                             "ERR_HEADER_SIZE expS=%lu expB=%lu dsp=%lu\n",
                                             (unsigned long)expected_samples,
                                             (unsigned long)expected_bytes,
                                             (unsigned long)EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE);
                                    send_text(dbg);
                                    reset_uart_session();
                                }
                            }
                            else
                            {
                                send_text("ERR_HEADER_PARSE\n");
                                reset_uart_session();
                            }
                        }
                        else
                        {
                            if (header_index < (HEADER_BUFFER_SIZE - 1))
                            {
                                header_buffer[header_index++] = (char)rx_byte;
                            }
                            else
                            {
                                send_text("ERR_HEADER_OVERFLOW\n");
                                reset_uart_session();
                            }
                        }
                    }
                    break;

      case STATE_RECEIVE_AUDIO: //stato di ricezione del payload audio

                    // ----- MODIFICA DMA QUI -----
                    // Nessun ciclo for, nessuna lettura bloccante.
                    // La CPU aspetta solo che il controller DMA metta questo flag a 1!
                    if (dma_rx_complete == 1)
                    {
                        send_text("RX_OK\n"); // Invio di conferma a MATLAB
                        uart_state = STATE_RUN_INFERENCE; // Passa all'inferenza
                    }
                    // ----------------------------
                    break;

          case STATE_RUN_INFERENCE: //Questo blocco passa i campioni audio al classificatore Edge Impulse, raccoglie i risultati e prepara il messaggio finale da mandare a MATLAB
          {
              signal_t features_signal; //Crea la struttura che Edge Impulse usa per accedere ai dati
              features_signal.total_length = EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE; //Dice quanti campioni totali ha il segnale
              features_signal.get_data = &raw_feature_get_data; //Collega il callback che fornisce i dati al classificatore

              ei_impulse_result_t result = { 0 }; //Inizializza la struttura di risultato
              EI_IMPULSE_ERROR res = run_classifier(&features_signal, &result, false); //Lancia l’inferenza

              if (res == EI_IMPULSE_OK) //Controlla se l’inferenza è andata a buon fine.
              {
                  char tx_buffer[128]; //Buffer temporaneo per formattare le stringhe da inviare

                  send_text("RESULT_BEGIN\n"); //Marca l’inizio dei risultati

                  for (size_t ix = 0; ix < EI_CLASSIFIER_LABEL_COUNT; ix++) //Cicla su tutte le label del modello
                  {
                      snprintf(tx_buffer, sizeof(tx_buffer), "%s: %.3f\n", //Prepara una riga con label e probabilità
                               result.classification[ix].label,
                               result.classification[ix].value);
                      send_text(tx_buffer);
                  }

                  snprintf(tx_buffer, sizeof(tx_buffer),
                           "TIMING dsp=%d ms, classification=%d ms, anomaly=%d ms\n", //Invia i tempi di elaborazione
                           result.timing.dsp,
                           result.timing.classification,
                           result.timing.anomaly);
                  send_text(tx_buffer);

                  size_t best_ix = 0; //Inizia la ricerca della label migliore dal primo elemento
                  for (size_t ix = 1; ix < EI_CLASSIFIER_LABEL_COUNT; ix++) //Confronta tutte le altre classi
                  {
                      if (result.classification[ix].value > result.classification[best_ix].value) //Tiene la probabilità più alta
                      {
                          best_ix = ix;
                      }
                  }

                  if ((strcmp(result.classification[best_ix].label, UNKNOWN_LABEL) != 0) &&
                      (result.classification[best_ix].value >= CLASSIFICATION_THRESHOLD)) //Esclude la classe unknown e richiede una soglia minima.
                  {
                      snprintf(tx_buffer, sizeof(tx_buffer), "TOP: %s %.3f\n", //Invia il nome della miglior classe e il relativo score.
                               result.classification[best_ix].label,
                               result.classification[best_ix].value);
                  }
                  else //Gestisce il caso in cui la previsione non sia abbastanza affidabile.
                  {
                      snprintf(tx_buffer, sizeof(tx_buffer), "TOP: PAROLA_NON_RICONOSCIUTA %.3f\n",
                               result.classification[best_ix].value);
                  }
                  send_text(tx_buffer);
              }
              else //Se run_classifier() fallisce, invii un errore.
              {
                  char tx_buffer[64];
                  snprintf(tx_buffer, sizeof(tx_buffer), "ERR_INFER %d\n", res); //Invii il codice errore.
                  send_text(tx_buffer);
              }

              uart_state = STATE_SEND_RESULT; //passa allo stato finale
              break;
          }

          case STATE_SEND_RESULT: //stato finale
              send_text("END_RESULT\n");
              HAL_GPIO_TogglePin(LD2_GPIO_Port, LD2_Pin);
              reset_uart_session();
              break;

          default:
              reset_uart_session();
              break;
      }
  }
  /* USER CODE END WHILE */

  /* USER CODE BEGIN 3 */

/* USER CODE END 3 */
}


/**
  * @brief System Clock Configuration
  * @retval None
  */
void SystemClock_Config(void)
{
  RCC_OscInitTypeDef RCC_OscInitStruct = {0};
  RCC_ClkInitTypeDef RCC_ClkInitStruct = {0};

  /** Configure the main internal regulator output voltage
  */
  __HAL_RCC_PWR_CLK_ENABLE();
  __HAL_PWR_VOLTAGESCALING_CONFIG(PWR_REGULATOR_VOLTAGE_SCALE2);

  /** Initializes the RCC Oscillators according to the specified parameters
  * in the RCC_OscInitTypeDef structure.
  */
  RCC_OscInitStruct.OscillatorType = RCC_OSCILLATORTYPE_HSI;
  RCC_OscInitStruct.HSIState = RCC_HSI_ON;
  RCC_OscInitStruct.HSICalibrationValue = RCC_HSICALIBRATION_DEFAULT;
  RCC_OscInitStruct.PLL.PLLState = RCC_PLL_ON;
  RCC_OscInitStruct.PLL.PLLSource = RCC_PLLSOURCE_HSI;
  RCC_OscInitStruct.PLL.PLLM = 16;
  RCC_OscInitStruct.PLL.PLLN = 336;
  RCC_OscInitStruct.PLL.PLLP = RCC_PLLP_DIV4;
  RCC_OscInitStruct.PLL.PLLQ = 7;
  if (HAL_RCC_OscConfig(&RCC_OscInitStruct) != HAL_OK)
  {
    Error_Handler();
  }

  /** Initializes the CPU, AHB and APB buses clocks
  */
  RCC_ClkInitStruct.ClockType = RCC_CLOCKTYPE_HCLK|RCC_CLOCKTYPE_SYSCLK
                              |RCC_CLOCKTYPE_PCLK1|RCC_CLOCKTYPE_PCLK2;
  RCC_ClkInitStruct.SYSCLKSource = RCC_SYSCLKSOURCE_PLLCLK;
  RCC_ClkInitStruct.AHBCLKDivider = RCC_SYSCLK_DIV1;
  RCC_ClkInitStruct.APB1CLKDivider = RCC_HCLK_DIV2;
  RCC_ClkInitStruct.APB2CLKDivider = RCC_HCLK_DIV1;

  if (HAL_RCC_ClockConfig(&RCC_ClkInitStruct, FLASH_LATENCY_2) != HAL_OK)
  {
    Error_Handler();
  }
}

/**
  * @brief USART2 Initialization Function
  * @param None
  * @retval None
  */
static void MX_USART2_UART_Init(void)
{

  /* USER CODE BEGIN USART2_Init 0 */

  /* USER CODE END USART2_Init 0 */

  /* USER CODE BEGIN USART2_Init 1 */

  /* USER CODE END USART2_Init 1 */
  huart2.Instance = USART2;
  huart2.Init.BaudRate = 460800;
  huart2.Init.WordLength = UART_WORDLENGTH_8B;
  huart2.Init.StopBits = UART_STOPBITS_1;
  huart2.Init.Parity = UART_PARITY_NONE;
  huart2.Init.Mode = UART_MODE_TX_RX;
  huart2.Init.HwFlowCtl = UART_HWCONTROL_NONE;
  huart2.Init.OverSampling = UART_OVERSAMPLING_16;
  if (HAL_UART_Init(&huart2) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN USART2_Init 2 */

  /* USER CODE END USART2_Init 2 */

}

/**
  * Enable DMA controller clock
  */
static void MX_DMA_Init(void)
{

  /* DMA controller clock enable */
  __HAL_RCC_DMA1_CLK_ENABLE();

  /* DMA interrupt init */
  /* DMA1_Stream5_IRQn interrupt configuration */
  HAL_NVIC_SetPriority(DMA1_Stream5_IRQn, 0, 0);
  HAL_NVIC_EnableIRQ(DMA1_Stream5_IRQn);

}

/**
  * @brief GPIO Initialization Function
  * @param None
  * @retval None
  */
static void MX_GPIO_Init(void)
{
  GPIO_InitTypeDef GPIO_InitStruct = {0};
  /* USER CODE BEGIN MX_GPIO_Init_1 */

  /* USER CODE END MX_GPIO_Init_1 */

  /* GPIO Ports Clock Enable */
  __HAL_RCC_GPIOC_CLK_ENABLE();
  __HAL_RCC_GPIOH_CLK_ENABLE();
  __HAL_RCC_GPIOA_CLK_ENABLE();
  __HAL_RCC_GPIOB_CLK_ENABLE();

  /*Configure GPIO pin Output Level */
  HAL_GPIO_WritePin(LD2_GPIO_Port, LD2_Pin, GPIO_PIN_RESET);

  /*Configure GPIO pin : B1_Pin */
  GPIO_InitStruct.Pin = B1_Pin;
  GPIO_InitStruct.Mode = GPIO_MODE_IT_FALLING;
  GPIO_InitStruct.Pull = GPIO_NOPULL;
  HAL_GPIO_Init(B1_GPIO_Port, &GPIO_InitStruct);

  /*Configure GPIO pin : LD2_Pin */
  GPIO_InitStruct.Pin = LD2_Pin;
  GPIO_InitStruct.Mode = GPIO_MODE_OUTPUT_PP;
  GPIO_InitStruct.Pull = GPIO_NOPULL;
  GPIO_InitStruct.Speed = GPIO_SPEED_FREQ_LOW;
  HAL_GPIO_Init(LD2_GPIO_Port, &GPIO_InitStruct);

  /* USER CODE BEGIN MX_GPIO_Init_2 */

  /* USER CODE END MX_GPIO_Init_2 */
}

/* USER CODE BEGIN 4 */



// Questa funzione viene chiamata in automatico dall'HAL quando il DMA finisce
void HAL_UART_RxCpltCallback(UART_HandleTypeDef *huart)
{
    if (huart->Instance == USART2)
    {
        dma_rx_complete = 1; // Avvisa il ciclo principale che abbiamo i dati!
    }
}

void reset_uart_session(void) //funzione per resettare l uart e portare tuto allo stato iniziale
{
    dma_rx_complete = 0; // <--- NUOVA RIGA: Azzera il flag di completamento del DMA

    rx_index = 0; //azzera indice di scrittura del buffer audio
    header_index = 0; //Azzera l’indice del buffer header.
    expected_samples = 0;
    expected_bytes = 0;
    memset(header_buffer, 0, sizeof(header_buffer)); //Svuota il buffer dell’header
    memset(rx_buffer, 0, sizeof(rx_buffer)); //Svuota il buffer audio
    uart_state = STATE_WAIT_HEADER; //Rimette la macchina a stati nella fase iniziale
}
int parse_header(char *header, uint32_t *samples, uint32_t *bytes) //Questa funzione legge una stringa tipo START 16000 32000 e ne estrae: comando, numero campioni e numero di byte
{
    char command[16] = {0};
    unsigned long tmp_samples = 0;
    unsigned long tmp_bytes = 0;

    int parsed = sscanf(header, "%15s %lu %lu", command, &tmp_samples, &tmp_bytes);

    if (parsed == 3 && strcmp(command, "START") == 0)
    {
        *samples = (uint32_t)tmp_samples;
        *bytes   = (uint32_t)tmp_bytes;
        return 1;
    }

    return 0;
}

void send_text(const char *text)
{
    if (HAL_UART_Transmit(&huart2, (uint8_t *)text, strlen(text), 1000) != HAL_OK)
    {
        Error_Handler();
    }
}
/* USER CODE END 4 */

/**
  * @brief  This function is executed in case of error occurrence.
  * @retval None
  */
void Error_Handler(void)
{
  /* USER CODE BEGIN Error_Handler_Debug */
  /* User can add his own implementation to report the HAL error return state */
  __disable_irq();
  while (1)
  {
  }
  /* USER CODE END Error_Handler_Debug */
}
#ifdef USE_FULL_ASSERT
/**
  * @brief  Reports the name of the source file and the source line number
  *         where the assert_param error has occurred.
  * @param  file: pointer to the source file name
  * @param  line: assert_param error line source number
  * @retval None
  */
void assert_failed(uint8_t *file, uint32_t line)
{
  /* USER CODE BEGIN 6 */
  /* User can add his own implementation to report the file name and line number,
     ex: printf("Wrong parameters value: file %s on line %d\r\n", file, line) */
  /* USER CODE END 6 */
}
#endif /* USE_FULL_ASSERT */

















