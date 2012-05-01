/*******************************************************************************
*
*  smooth.cu
*
*  This provides a CUDA implementation of a kernel smooother.
*   http://en.wikipedia.org/wiki/Kernel_smoother
*  The particular smoother in this file is a nearest neighbor smoother
*  in order to keep the code as simple to understand as possible.
*
*  This is implemeneted for 2-d square grids.
*
*  Parameters of note:
*    dataWidth -- size of the data is dataWidth^2
*    halfWidth -- region around point x,y to smooth
*        k smooths box with corners [x-k,y-k] to [x+k,y+k]
*
*  The smoothed region is only defined for the interior that has the kernel
*   defined inside the boundary, e.g. for dataWidth=10, halfWidth=2 the
*   region from 2,2 to 7,7 will be smoothed. 
*
********************************************************************************/

/*******************************************************************************
*
*  CUDA concepts
*
*  This file shows how to use many features of CUDA:
*     2d grids
*     pitch allocation
*     shared memory
*
********************************************************************************/

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include <sys/time.h>

#include <cuda.h>

// Data is of size dataWidth * dataWidth
//const unsigned int dataWidth = 4112;

// Parameter to express the smoothing kernel halfwidth
//const unsigned int halfWidth = 8;

// Size of the CUDA threadBlock
//const unsigned int blockWidth = 16;

/* Small values good for testing */

// Data is of size dataWidth * dataWidth
const unsigned int dataWidth = 14;

// Parameter to express the smoothing kernel halfwidth
const unsigned int halfWidth = 1;
const unsigned int kernelWidth = halfWidth*2+1;

// Size of the CUDA threadBlock
const unsigned int blockWidth = 4;





/*------------------------------------------------------------------------------
* Name: NNSmoothKernel
* Action:  The CUDA kernel that implements kernel smoothing.
*             Yuck, that's two senses of kernel.
*-----------------------------------------------------------------------------*/
__global__ void NNSmoothKernel ( float* pFieldIn, float* pFieldOut, size_t pitch )
{ 
  extern __shared__ float shared[][blockWidth+kernelWidth-1];

  // pitch is in bytes, figure out the number of elements for addressing
  unsigned pitchels = pitch/sizeof(float);

  // compute the halfwidth-1 of the kernel
  unsigned koffset = (kernelWidth-1)/2;


  // Construct the 2d shared memory array it needs to be blockWidth+(kernelWidth-1)/2 square
  // Each node loads one element
  shared[threadIdx.x][threadIdx.y] = 
    pFieldIn [  (blockIdx.y * blockDim.y + threadIdx.y) * pitchels 
                   +  blockIdx.x * blockDim.x + threadIdx.x ];

  // And determines if it needs to load it's x-neigbor
  if ( threadIdx.x < kernelWidth -1 )
  {
    shared[threadIdx.x + blockWidth][threadIdx.y] = 
      pFieldIn [  (blockIdx.y * blockDim.y + threadIdx.y) * pitchels 
                     +  blockIdx.x * blockDim.x + threadIdx.x + blockWidth ];
  }

  // And determines if it needs to load it's y-neigbor
  if ( threadIdx.y < kernelWidth -1 )
  {
    shared[threadIdx.x][threadIdx.y + blockWidth] = 
      pFieldIn [  (blockIdx.y * blockDim.y + threadIdx.y + blockWidth) * pitchels 
                     +  blockIdx.x * blockDim.x + threadIdx.x];
  }

  // And determines if it needs to load it's xy-neigbor
  if ( ( threadIdx.y < kernelWidth -1 ) && ( threadIdx.x < kernelWidth -1 ))
  {
    shared[threadIdx.x + blockWidth][threadIdx.y + blockWidth] = 
      pFieldIn [  (blockIdx.y * blockDim.y + threadIdx.y + blockWidth) * pitchels 
                     +  blockIdx.x * blockDim.x + threadIdx.x + blockWidth];
  }

  __syncthreads();

  pFieldOut [ (threadIdx.y+koffset)*pitchels + threadIdx.x+koffset ] = shared [threadIdx.x][threadIdx.y];


  // Variable to accumulate the smoothed value
  float value = 0.0;

  // The grid indexes start from 
  unsigned xindex = ( blockIdx.x * blockDim.x + threadIdx.x) + koffset; 
  unsigned yindex = ( blockIdx.y * blockDim.y + threadIdx.y) + koffset; 

  // Get the value from the kernel
  for ( unsigned j=0; j<kernelWidth; j++ )
  {
    for ( unsigned i=0; i<kernelWidth; i++ )
    {
      value += shared [threadIdx.x+i] [threadIdx.y+j];
    }
  }
  
  // Divide by the number of elements in the kernel
  value /= kernelWidth*kernelWidth;

  // Write the value out 
  pFieldOut [ yindex*pitchels + xindex ] = value;


} 


/*------------------------------------------------------------------------------
* Name:  SmoothField
* Action:  Host entry point to kernel smoother
*-----------------------------------------------------------------------------*/
bool SmoothField ( float* pHostFieldIn, float *pHostFieldOut ) 
{ 
  float * pDeviceFieldIn = 0;
  float * pDeviceFieldOut = 0;

  size_t pitch, pitchout;

  struct timeval ta, tb, tc, td;

  // Check the grid dimensions and extract parameters.  See top description about restrictions
//  assert ((( kernelWidth -1 )%2) == 0 );     // Width is odd
//  assert((gridWidth-(kernelWidth-1) % blockWidth == 0 );

  gettimeofday ( &ta, NULL );

  // Place the data set on device memory
  cudaMallocPitch((void**)&pDeviceFieldIn, &pitch, dataWidth*sizeof(float), dataWidth ); 
  cudaMemcpy2D ( pDeviceFieldIn, pitch,
                 pHostFieldIn, dataWidth*sizeof(float), dataWidth*sizeof(float), dataWidth,
                 cudaMemcpyHostToDevice); 

  // Allocate the output
  cudaMallocPitch((void**)&pDeviceFieldOut, &pitchout, dataWidth*sizeof(float), dataWidth ); 

  gettimeofday ( &tb, NULL );

  // Construct a 2d grid/block
  const dim3 DimBlock ( blockWidth, blockWidth );
  const dim3 DimGrid ( (dataWidth-(kernelWidth-1))/blockWidth , 
                       (dataWidth-(kernelWidth-1))/blockWidth );
  const unsigned shmemSize = ( blockWidth + kernelWidth -1 ) * ( blockWidth + kernelWidth -1 ) * sizeof (float);

  // Invoke the kernel
  NNSmoothKernel <<<DimGrid,DimBlock, shmemSize>>> ( pDeviceFieldIn, pDeviceFieldOut, pitch ); 

  gettimeofday ( &tc, NULL );

  // Retrieve the results
  cudaMemcpy2D(pHostFieldOut, dataWidth*sizeof(float), 
               pDeviceFieldOut, pitch, dataWidth*sizeof(float), dataWidth,
               cudaMemcpyDeviceToHost); 

  gettimeofday ( &td, NULL );


  if ( ta.tv_usec < td.tv_usec )
  {
    printf ("Elapsed total time (s/m): %d:%d\n", td.tv_sec - ta.tv_sec, td.tv_usec - ta.tv_usec );
  } else {
    printf ("Elapsed total time (s/m): %d:%d\n", td.tv_sec - ta.tv_sec - 1, 1000000 - td.tv_usec + ta.tv_usec );
  }

  if ( tb.tv_usec < tc.tv_usec )
  {
    printf ("Elapsed kernel time (s/m): %d:%d\n", tc.tv_sec - tb.tv_sec, tc.tv_usec - tb.tv_usec );
  } else {
    printf ("Elapsed kernel time (s/m): %d:%d\n", tc.tv_sec - tb.tv_sec - 1, 1000000 - tc.tv_usec + tb.tv_usec );
  }

  return true;
}



/*------------------------------------------------------------------------------
* Name:  initField
* Action:  Initialize a field to predictable values.
*    This is a useful format for debugging, because values 
*    accumulate to their initial value.
*-----------------------------------------------------------------------------*/
void initField ( unsigned dim, float* pField )
{
  for ( unsigned j=0; j<dim; j++ )
  {
    for ( unsigned i=0; i<dim; i++ )
    {
      pField[j*dim+i] = j + i;
    }
  }
}


/*------------------------------------------------------------------------------
* Name:  main
* Action:  Entry point
*-----------------------------------------------------------------------------*/
int main ()
{
  // Create the input field
  float *field = (float *) malloc ( dataWidth * dataWidth * sizeof(float));
  initField ( dataWidth, field );

  // Create the output field
  float *out = (float *) malloc ( dataWidth * dataWidth * sizeof(float));

  // Call the kernel
  SmoothField ( field, out );

  // Print the output field (for debugging purposes.
  unsigned koffset = (kernelWidth-1)/2;
  for ( unsigned j=0; j< dataWidth; j++ )
  {
    for ( unsigned i=0; i< dataWidth; i++ )
    {
      if ( ( i >= koffset ) && 
           ( j >= koffset ) &&
           ( i < ( dataWidth - koffset )) &&
           ( j < ( dataWidth - koffset )) )
      {
        printf ("%4.4f, ", out[j*dataWidth + i]);
      }
      else
      {
        printf ("%4.4f, ", 0.0f );
      }
    }  
    printf ("\n");
  }

}
