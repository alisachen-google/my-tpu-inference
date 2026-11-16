| Config | Job | Concurrency | Tok/s per chip | M tokens per $ | p90 interactivity tok/s | Mean TTFT s | p90 TTFT s | p90 E2E s |
|---|---|---|---|---|---|---|---|---|
| GB300, TRT, aggregated TP4, 4 GPUs | `j-84aea0c8-daed-482f-a9ec` | 1 | 5,979 | 9.3 | 429 | 1.1 | 1.5 | 13.5 |
| GB300, TRT, aggregated TP4, 4 GPUs | `j-68002519-20a9-4c05-8838` | 4 | 8,752 | 13.6 | 332 | 0.7 | 1.3 | 10.8 |
| GB300, TRT, aggregated TP4, 4 GPUs | `j-e8a8950c-bafa-40ff-b2c4` | 8 | 14,896 | 23.2 | 270 | 0.8 | 1.5 | 9.8 |
| GB300, TRT, aggregated TP4, 4 GPUs | `j-0478ffcc-7819-488d-9887` | 20 | 34,282 | 53.4 | 185 | 1.4 | 2.3 | 14.5 |
| GB300, TRT, aggregated TP4, 4 GPUs | `j-8a55c8c6-69f0-4b98-b206` | 32 | 49,448 | 77.1 | 126 | 3.1 | 9.0 | 22.2 |
| GB300, TRT, aggregated TP4, 4 GPUs | `j-e6514750-19e3-4c95-8291` | 48 | 64,194 | 100.0 | 91 | 2.3 | 4.9 | 25.3 |
| VR200, Dynamo+TRT, aggregated TP4, 4 GPUs | `j-70cdd590-d42b-4e8b-bc1c` | 24 | 44,364 | 44.2 | 391 | 3.1 | 8.1 | 12.3 |
| VR200, Dynamo+TRT, aggregated TP4, 4 GPUs | `j-a3c27ac7-e8ca-425a-9c3e` | 48 | 85,017 | 84.8 | 193 | 0.8 | 1.3 | 12.8 |
| VR200, Dynamo+TRT, aggregated TP4, 4 GPUs | `j-f7a07815-5bd3-4ec1-9ca2` | 96 | 137,647 | 137.3 | 107 | 1.3 | 3.0 | 20.2 |
| VR200, aggregated TP8, 8 GPUs | `j-70b474a2-9f32-4f22-9ec8` | 1 | 4,177 | 4.2 | 990 | 0.2 | 0.3 | 4.8 |
| VR200 disagg, 4 decode x TP4, 20 GPUs | `j-897fccad-b3d1-4330-bde0` | 100 | 34,645 | 34.5 | 463 | 3.1 | 7.7 | 11.1 |
| VR200 disagg, 5 decode x TP4, 24 GPUs | `j-7a091968-7961-47f5-8f83` | 100 | 28,561 | 28.5 | 541 | 3.9 | 9.3 | 12.2 |
| VR200 disagg, 7 decode x TP4, 32 GPUs | `j-82d77041-02e7-497a-8b09` | 84 | 19,684 | 19.6 | 752 | 3.5 | 8.5 | 10.9 |
| VR200 disagg, 4 decode x TP8, 36 GPUs | `j-0c1f8009-20af-456a-b80d` | 56 | 12,967 | 12.9 | 971 | 2.1 | 5.3 | 7.1 |
| **TPU7x SGLang P/D, PP8 prefill + TP8 decode, 8 chips** | `j-ec9464b2-4aaf-46fe-af8a` | 32 | 18,326 | 54.5 | 64 | 7.1 | 12.8 | 35.8 |
| TPU7x SGLang aggregated TP8, 4 chips (latest sweep) | `j-24fcba7c-f94c-4b32-bc17` | 1 | 6,449 | 19.2 | 487 | 1.3 | 1.9 | 11.3 |
| TPU7x SGLang aggregated TP8, 4 chips (latest sweep) | `j-500bf362-a814-44c3-a12d` | 7 | 12,118 | 36.1 | 340 | 1.7 | 4.0 | 10.7 |
| TPU7x SGLang aggregated TP8, 4 chips (latest sweep) | `j-7519d90e-ac9e-4e75-bc38` | 9 | 15,775 | 46.9 | 286 | 2.7 | 6.7 | 13.6 |
| TPU7x SGLang aggregated TP8, 4 chips (latest sweep) | `j-72a31b3f-5555-4c21-bb77` | 10 | 17,139 | 51.0 | 229 | 1.8 | 3.4 | 12.7 |
| TPU7x SGLang aggregated TP8, 4 chips (latest sweep) | `j-e7259334-164f-4f3d-b372` | 16 | 23,314 | 69.4 | 166 | 3.8 | 8.6 | 21.8 |
| TPU7x SGLang aggregated TP8, 4 chips (latest sweep) | `j-6bbec2a7-2efb-4b81-9291` | 22 | 29,213 | 86.9 | 109 | 5.7 | 15.3 | 33.7 |