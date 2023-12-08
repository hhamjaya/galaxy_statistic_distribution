/*
Compile with
nvcc -arch=sm_70 galaxies.cu -o a.out -lm
srun -p gpu --mem=1G -t 1:00:00 ./a.out real_data.txt sim_data.txt out.txt

srun -p gpu --mem=1G -t=1:00:00 –o prog.out –e prog.err./a.out real_data sim_data out.txt

module load GCC/7.3.0-2.30
*/

#include <cuda.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <sys/time.h>

#define totaldegrees 180
#define binsperdegree 4
#define threadsperblock 512


// data for the real galaxies will be read into these arrays
float *ra_real, *decl_real;
float *d_ra_real, *d_decl_real;
// number of real galaxies
int    NoofReal;

// data for the simulated random galaxies will be read into these arrays
float *ra_sim, *decl_sim;
float *d_ra_sim, *d_decl_sim;
// number of simulated random galaxies
int    NoofSim;

unsigned int *histogramDR, *histogramDD, *histogramRR;
unsigned int *d_histogramDR, *d_histogramDD, *d_histogramRR;
float *w_histogram,*d_w_histogram;


__global__ void calculate_angles(float *D_ra,float *D_decl,float *R_ra, float *R_decl,unsigned int *histogramDR,unsigned int *histogramDD,unsigned int *histogramRR){
    int i = blockDim.x * blockIdx.x + threadIdx.x;
    int N=100000;
    int size_hist=180*4;
    double result,alpha1,theta1,alpha2,theta2;
    double c_rads=(M_PI / (180.0 * 60.0));
    unsigned int histogramTemp[180*4];

    if(i<N*3){
        for(int j=0;j<size_hist;j++){
            histogramTemp[j]=0;
        }
    }
    
    if(i < N){//DR
        alpha1=D_ra[i] * c_rads; 
        theta1=(D_decl[i]) *c_rads; 
        for (int j=0;j<N;j++){
            alpha2=R_ra[j]*c_rads;
            theta2= (R_decl[j]) *c_rads; 
            result =acos(sin(theta1) * sin(theta2) + cos(theta1) * cos(theta2) * cos(alpha1 - alpha2));
            result=result*(180/M_PI );
            int index=(int)(result*4);
            histogramTemp[index]+=1;
        }
        //Copy the data
        for(int j=0;j<size_hist;j++){
            atomicAdd(&histogramDR[j], histogramTemp[j]);
        }
    }else if(i>=N && i<2*N) {
        i=i-N;

        alpha1=D_ra[i] * c_rads; 
        theta1=(D_decl[i]) *c_rads; 
        //DD
        for (int j=0;j<N;j++){
            alpha2=D_ra[j]*c_rads;
            theta2= (D_decl[j]) *c_rads; 
            result =acos(sin(theta1) * sin(theta2) + cos(theta1) * cos(theta2) * cos(alpha1 - alpha2));
            result=result*(180/M_PI );
            int index=(int)(result*4);
            histogramTemp[index]+=1;
        }
        //Copy the data
        for(int j=0;j<size_hist;j++){
            atomicAdd(&histogramDD[j], histogramTemp[j]);
        }
    }else if(i>=2*N && i<3*N){
        i=i-2*N;
        // //RR
        alpha1=R_ra[i] * c_rads; 
        theta1=(R_decl[i]) *c_rads; 
        for (int j=0;j<N;j++){
            alpha2=R_ra[j]*c_rads;
            theta2= (R_decl[j]) *c_rads; 
            result =acos(sin(theta1) * sin(theta2) + cos(theta1) * cos(theta2) * cos(alpha1 - alpha2));
            result=result*(180/M_PI );
            int index=(int)(result*4);
            histogramTemp[index]+=1;
        }
        //Copy the data
        for(int j=0;j<size_hist;j++){
            atomicAdd(&histogramRR[j], histogramTemp[j]);
        }
    }


} 

__global__ void calculate_omega(unsigned int *histogramDR,unsigned int *histogramDD,unsigned int *histogramRR,float *w_histogram){
    int i = blockDim.x * blockIdx.x + threadIdx.x;
    w_histogram[i]=(float)(histogramDD[i]-2*histogramDR[i]+histogramRR[i])/histogramRR[i];
 
}
int readdatapoints(char *filename,float **ra_list,float **decl_list, int *announcednumber){
    FILE *infil;
    char inbuf[180];
    double ra, dec;

    infil = fopen(filename,"r");
    if ( infil == NULL ) {printf("Cannot open input file %s\n",filename);return(-1);}

    // read the number of galaxies in the input file
    if ( fscanf(infil,"%d\n",announcednumber) != 1 ) {printf(" cannot read file %s\n",filename);return(-1);}

    *ra_list   = (float *)calloc(*announcednumber,sizeof(float));
    *decl_list   = (float *)calloc(*announcednumber,sizeof(float));
    int i =0;
    while ( fgets(inbuf,80,infil) != NULL )    {
        if ( sscanf(inbuf,"%lf %lf",&ra,&dec) != 2 ){
            printf("   Cannot read line %d in %s\n",i+1,filename);
            fclose(infil);
            return(-1);
        }
        (*ra_list)[i]   = (float)ra;
        (*decl_list)[i] = (float)dec;
        ++i;
    }

    fclose(infil);
    return 0;
}

int getDevice(int deviceNo){

  int deviceCount;
  cudaGetDeviceCount(&deviceCount);
  printf("   Found %d CUDA devices\n",deviceCount);
  if ( deviceCount < 0 || deviceCount > 128 ) return(-1);
  int device;
  for (device = 0; device < deviceCount; ++device) {
       cudaDeviceProp deviceProp;
       cudaGetDeviceProperties(&deviceProp, device);
       printf("      Device %s                  device %d\n", deviceProp.name,device);
       printf("         compute capability            =        %d.%d\n", deviceProp.major, deviceProp.minor);
       printf("         totalGlobalMemory             =       %.2lf GB\n", deviceProp.totalGlobalMem/1000000000.0);
       printf("         l2CacheSize                   =   %8d B\n", deviceProp.l2CacheSize);
       printf("         regsPerBlock                  =   %8d\n", deviceProp.regsPerBlock);
       printf("         multiProcessorCount           =   %8d\n", deviceProp.multiProcessorCount);
       printf("         maxThreadsPerMultiprocessor   =   %8d\n", deviceProp.maxThreadsPerMultiProcessor);
       printf("         sharedMemPerBlock             =   %8d B\n", (int)deviceProp.sharedMemPerBlock);
       printf("         warpSize                      =   %8d\n", deviceProp.warpSize);
       printf("         clockRate                     =   %8.2lf MHz\n", deviceProp.clockRate/1000.0);
       printf("         maxThreadsPerBlock            =   %8d\n", deviceProp.maxThreadsPerBlock);
       printf("         asyncEngineCount              =   %8d\n", deviceProp.asyncEngineCount);
       printf("         f to lf performance ratio     =   %8d\n", deviceProp.singleToDoublePrecisionPerfRatio);
       printf("         maxGridSize                   =   %d x %d x %d\n",
                          deviceProp.maxGridSize[0], deviceProp.maxGridSize[1], deviceProp.maxGridSize[2]);
       printf("         maxThreadsDim in thread block =   %d x %d x %d\n",
                          deviceProp.maxThreadsDim[0], deviceProp.maxThreadsDim[1], deviceProp.maxThreadsDim[2]);
       printf("         concurrentKernels             =   ");
       if(deviceProp.concurrentKernels==1) printf("     yes\n"); else printf("    no\n");
       printf("         deviceOverlap                 =   %8d\n", deviceProp.deviceOverlap);
       if(deviceProp.deviceOverlap == 1)
       printf("            Concurrently copy memory/execute kernel\n");
       }

    cudaSetDevice(deviceNo);
    cudaGetDevice(&device);
    if ( device != 0 ) printf("   Unable to set device 0, using %d instead",device);
    else printf("   Using CUDA device %d\n\n", device);

return(0);
}

unsigned long long int sumHist(unsigned int *histogram,int N){
    unsigned long long int temp=0;
    for(int i=0;i<N;i++)temp+=histogram[i];
    return temp;
}

int main(int argc, char *argv[]){

//    int    i;
   int    getDevice(int deviceno);
   unsigned long long histogramDRsum, histogramDDsum, histogramRRsum;
   int size_hist= totaldegrees*binsperdegree ;
//    double w;
   double start, end, kerneltime;
   struct timeval _ttime;
   struct timezone _tzone;

    kerneltime = 0.0;
    gettimeofday(&_ttime, &_tzone);
    start = (double)_ttime.tv_sec + (double)_ttime.tv_usec/1000000.;
   cudaError_t cudaStatus ;

//    FILE *outfil;

   if ( argc != 4 ) {printf("Usage: a.out real_data random_data output_data\n");return(-1);}

// //    if ( getDevice(0) != 0 ) return(-1);


    //Initilize histogram
    histogramDR   = (unsigned int*)calloc(size_hist,sizeof(unsigned int));
    histogramDD   = (unsigned int*)calloc(size_hist,sizeof(unsigned int));
    histogramRR   = (unsigned int*)calloc(size_hist,sizeof(unsigned int));
    w_histogram   = (float*)calloc(size_hist,sizeof(float));

    //Read the data
    if ( readdatapoints(argv[1],&ra_real, &decl_real,&NoofReal) != 0 ) return(-1);
    if ( readdatapoints(argv[2],&ra_sim, &decl_sim,&NoofSim) != 0 ) return(-1);

    printf("Number %d of real galaxies and first value of ra_real %.2f and first value of ra_sim %.2f \n",NoofReal,ra_real[0],ra_sim[0]);
   
   // allocate and copy mameory on the GPU
    size_t arraybytes = NoofSim * sizeof(float); 
    cudaMalloc(&d_ra_real, arraybytes);
    cudaMalloc(&d_decl_real, arraybytes);    
    cudaMalloc(&d_ra_sim, arraybytes);
    cudaMalloc(&d_decl_sim, arraybytes);

    cudaMemcpy(d_ra_real, ra_real, arraybytes, cudaMemcpyHostToDevice); 
    cudaMemcpy(d_decl_real, decl_real, arraybytes, cudaMemcpyHostToDevice); 
    cudaMemcpy(d_ra_sim, ra_sim, arraybytes, cudaMemcpyHostToDevice); 
    cudaMemcpy(d_decl_sim, decl_sim, arraybytes, cudaMemcpyHostToDevice); 


    arraybytes = size_hist* sizeof(unsigned int); 
    cudaMallocManaged(&d_histogramDR, arraybytes);
    cudaMallocManaged(&d_histogramDD, arraybytes);
    cudaMallocManaged(&d_histogramRR, arraybytes);

    cudaMemcpy(d_histogramDR, histogramDR, arraybytes, cudaMemcpyHostToDevice); 
    cudaMemcpy(d_histogramDD, histogramDD, arraybytes, cudaMemcpyHostToDevice); 
    cudaMemcpy(d_histogramRR, histogramRR, arraybytes, cudaMemcpyHostToDevice); 



   // run the kernels on the GPU
    int blocksInGrid = (NoofReal*3 + threadsperblock - 1) / threadsperblock;
    calculate_angles<<<blocksInGrid, threadsperblock>>>(d_ra_real, d_decl_real, d_ra_sim, d_decl_sim,d_histogramDR,d_histogramDD,d_histogramRR); 

    // Check for any errors launching the kernel
    cudaStatus = cudaGetLastError();
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "calculate_angles launch failed: %s\n", cudaGetErrorString(cudaStatus));
        // You may want to add additional cleanup code here
        return 1;
    }

    arraybytes = size_hist* sizeof(unsigned int); 
    cudaMemcpy(histogramDD, d_histogramDD, arraybytes, cudaMemcpyDeviceToHost); 
    cudaMemcpy(histogramDR, d_histogramDR, arraybytes, cudaMemcpyDeviceToHost); 
    cudaMemcpy(histogramRR, d_histogramRR, arraybytes, cudaMemcpyDeviceToHost); 


    // histogramDRsum= sumHist(histogramDR,size_hist);
    // histogramDDsum= sumHist(histogramDD,size_hist);
    // histogramRRsum= sumHist(histogramRR,size_hist);

    // printf("Resultado de histogramDRsum  %llu  %llu  %llu\n",histogramDRsum,histogramDDsum,histogramRRsum);


    
    //Calculate omega
    arraybytes = size_hist* sizeof(float); 
    cudaMallocManaged(&d_w_histogram, arraybytes);
    cudaMemcpy(d_w_histogram, w_histogram, arraybytes, cudaMemcpyHostToDevice);
   // run the kernels on the GPU
    blocksInGrid = (size_hist + threadsperblock - 1) / threadsperblock;
    calculate_omega<<<blocksInGrid, threadsperblock>>>(d_histogramDR,d_histogramDD,d_histogramRR,d_w_histogram); 

    // Check for any errors launching the kernel
    cudaStatus = cudaGetLastError();
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "calculate_angles launch failed: %s\n", cudaGetErrorString(cudaStatus));
        // You may want to add additional cleanup code here
        return 1;
    }
    
    cudaMemcpy(w_histogram, d_w_histogram, arraybytes, cudaMemcpyDeviceToHost); 
        
    gettimeofday(&_ttime, &_tzone);
    end = (double)_ttime.tv_sec + (double)_ttime.tv_usec/1000000.;
    kerneltime += end-start;
    printf("\n\n Total time %.4f\n\n ",kerneltime);

    // Print the header
    printf("%-15s %-15s %-15s %-15s %-15s\n", "bin start/deg", "omega", "hist_DD", "hist_DR", "hist_RR");
    printf("%-15s %-15s %-15s %-15s %-15s\n", "-------------", "-----", "-------", "-------", "-------");

    // Print the first ten values
    for (int i = 0; i < 10; ++i) {
        printf("%-15.4f %-15.4f %-15u %-15u %-15u\n", 0.25 * i, w_histogram[i], histogramDD[i], histogramDR[i], histogramRR[i]);
    }
    printf("\n");


    // Free memory
    cudaFree(d_ra_real); cudaFree(d_decl_real); cudaFree(d_ra_sim);cudaFree(d_decl_sim);  
    cudaFree(d_histogramDD); cudaFree(d_histogramDR); cudaFree(d_histogramRR);  
    cudaFree(d_w_histogram);

    free(ra_real); free(decl_real); free(ra_sim); free(decl_sim);
    free(histogramDR); free(histogramDD); free(histogramRR);
    free(w_histogram);
   return(0);
}
