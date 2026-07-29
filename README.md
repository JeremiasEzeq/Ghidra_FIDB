# Script de generación de bases de datos de identificación de funciones en firmwares de sistemas embebidos

## Contexto
Un problema común en la ingeniería inversa con firmwares de sistemas embebidos es que estos suelen distribuirse sin símbolos. Esto ralentiza en gran medida el proceso de análisis, obligando a los usuarios a dedicar tiempo a identificar funciones que podrían ser de librerías ya conocidas, en lugar de analizar el resto del binario.

Para mitigar este problema, Ghidra ofrece una forma de identificar funciones comunes para entender más rápidamente el funcionamiento de un binario: las FIDBs. Una FIDB, o Base de Datos de Identificación de Funciones, es un formato de base de datos utilizado por el analizador FunctionID de Ghidra para almacenar los hashes de las funciones. Estos hashes permiten reconocer funciones sin necesidad de símbolos.

## Descripción
El objetivo de este trabajo es la creación de un pipeline de generación de FIDBs a partir de librerías para acelerar el proceso de análisis de firmwares de sistemas embebidos. Ya existen otros proyectos con un objetivo similar, como el generador de FIDBs de threatrack (actualmente deprecado), o el más reciente generador de FIDBs de itwaseasy. Sin embargo, estos generan las FIDBs a partir de paquetes `.deb`, lo que limita los proyectos a distribuciones basadas en Debian. Este pipeline busca proveer una solución independiente de la distribución para un número de librerías de uso general compilándolas a partir del código fuente. Además, se permite la selección de arquitectura para la que se quiere compilar, permitiendo más flexibilidad en los firmwares que se desean analizar.


## Tecnologías utilizadas
El proyecto utiliza principalmente Ghidra para el análisis y creación de base FIDBs, concretamente se usa la herramienta de ghidra headless.

## Supuestos y limitaciones
`compile.sh` necesita expandirse manualmente para cada librería que se desea soportar, dado que cada librería tiene un proceso de compilado distinto.