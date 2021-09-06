#include "lesson_5.cuh"

#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
//#include <thrust/count.h>
//#include <thrust/copy.h>
//#include <thrust/fill.h>
#include <thrust/sort.h>
//#include <thrust/sequence.h>
#include <thrust/extrema.h>

#include "cuda_SVD.cu"

__global__ void kernel_cudaWarmUpGPU()
{
	int ind=blockIdx.x*blockDim.x+threadIdx.x;
	ind = ind + 1;
}

cudaError_t cudaWarmUpGPU()
{
	kernel_cudaWarmUpGPU<<<1,1>>>();
	cudaDeviceSynchronize();
	return cudaGetLastError();
}

cudaError_t cudaCalculateGridParams(pcl::PointNormal* d_point_cloud, int number_of_points, 
	float resolution_X, float resolution_Y, float resolution_Z, gridParameters &out_rgd_params)
{
	cudaError_t err = cudaGetLastError();

	try
	{
		thrust::device_ptr<pcl::PointNormal> t_cloud(d_point_cloud);
		err = cudaGetLastError();
		if(err != ::cudaSuccess)return err;
	
		thrust::pair<thrust::device_ptr<pcl::PointNormal>,thrust::device_ptr<pcl::PointNormal> >
		 minmaxX=thrust::minmax_element(t_cloud,t_cloud+number_of_points,compareX());
		err = cudaGetLastError();
		if(err != ::cudaSuccess)return err;
	
		thrust::pair<thrust::device_ptr<pcl::PointNormal>,thrust::device_ptr<pcl::PointNormal> >
		 minmaxY=thrust::minmax_element(t_cloud,t_cloud+number_of_points,compareY());
		err = cudaGetLastError();
		if(err != ::cudaSuccess)return err;
	
		thrust::pair<thrust::device_ptr<pcl::PointNormal>,thrust::device_ptr<pcl::PointNormal> >
		 minmaxZ=thrust::minmax_element(t_cloud,t_cloud+number_of_points,compareZ());
		err = cudaGetLastError();
		if(err != ::cudaSuccess)return err;
		
		pcl::PointNormal minX,maxX,minZ,maxZ,minY,maxY;

		err = cudaMemcpy(&minX,minmaxX.first.get(),sizeof(pcl::PointNormal),cudaMemcpyDeviceToHost);
		if(err != ::cudaSuccess)return err;
		err = cudaMemcpy(&maxX,minmaxX.second.get(),sizeof(pcl::PointNormal),cudaMemcpyDeviceToHost);
		if(err != ::cudaSuccess)return err;
		err = cudaMemcpy(&minZ,minmaxZ.first.get(),sizeof(pcl::PointNormal),cudaMemcpyDeviceToHost);
		if(err != ::cudaSuccess)return err;
		err = cudaMemcpy(&maxZ,minmaxZ.second.get(),sizeof(pcl::PointNormal),cudaMemcpyDeviceToHost);
		if(err != ::cudaSuccess)return err;
		err = cudaMemcpy(&minY,minmaxY.first.get(),sizeof(pcl::PointNormal),cudaMemcpyDeviceToHost);
		if(err != ::cudaSuccess)return err;
		err = cudaMemcpy(&maxY,minmaxY.second.get(),sizeof(pcl::PointNormal),cudaMemcpyDeviceToHost);
		if(err != ::cudaSuccess)return err;
	
		int number_of_buckets_X=((maxX.x-minX.x)/resolution_X)+1;
		int number_of_buckets_Y=((maxY.y-minY.y)/resolution_Y)+1;
		int number_of_buckets_Z=((maxZ.z-minZ.z)/resolution_Z)+1;

		out_rgd_params.number_of_buckets_X=number_of_buckets_X;
		out_rgd_params.number_of_buckets_Y=number_of_buckets_Y;
		out_rgd_params.number_of_buckets_Z=number_of_buckets_Z;
		out_rgd_params.number_of_buckets = number_of_buckets_X * number_of_buckets_Y * number_of_buckets_Z;
		
		out_rgd_params.bounding_box_max_X=maxX.x;
		out_rgd_params.bounding_box_min_X=minX.x;
		out_rgd_params.bounding_box_max_Y=maxY.y;
		out_rgd_params.bounding_box_min_Y=minY.y;
		out_rgd_params.bounding_box_max_Z=maxZ.z;
		out_rgd_params.bounding_box_min_Z=minZ.z;
		
		out_rgd_params.resolution_X=resolution_X;
		out_rgd_params.resolution_Y=resolution_Y;
		out_rgd_params.resolution_Z=resolution_Z;
	}
	catch(thrust::system_error &e)
	{
		err = cudaGetLastError();
		cudaDeviceReset();
		return err;
	}	
	catch(std::bad_alloc &e)
  	{
  	 	err = cudaGetLastError();
		cudaDeviceReset();
		return err;
  	}	
	return cudaGetLastError();
}

__global__ void kernel_initializeIndByKey(hashElement* d_hashTable, int number_of_points)
{
	int ind=blockIdx.x*blockDim.x+threadIdx.x;
	if(ind < number_of_points)
	{
		d_hashTable[ind].index_of_point=ind;
		d_hashTable[ind].index_of_bucket=0;
	}
}

__global__ void kernel_getIndexOfBucketForPoints(pcl::PointNormal* d_point_cloud,
		hashElement* d_hashTable, int number_of_points, gridParameters rgd_params)
{
	int ind=blockIdx.x*blockDim.x+threadIdx.x;
	if(ind<number_of_points)
	{
		int ix=(d_point_cloud[ind].x-rgd_params.bounding_box_min_X)/rgd_params.resolution_X;
		int iy=(d_point_cloud[ind].y-rgd_params.bounding_box_min_Y)/rgd_params.resolution_Y;
		int iz=(d_point_cloud[ind].z-rgd_params.bounding_box_min_Z)/rgd_params.resolution_Z;
		d_hashTable[ind].index_of_bucket=ix*rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z+iy*rgd_params.number_of_buckets_Z+iz;
	}
}

__global__ void kernel_initializeBuckets(bucket* d_buckets, gridParameters rgd_params)
{
	long long int ind=blockIdx.x*blockDim.x+threadIdx.x;
	if(ind < rgd_params.number_of_buckets)
	{
		d_buckets[ind].index_begin=-1;
		d_buckets[ind].index_end=-1;
		d_buckets[ind].number_of_points=0;
	}
}

__global__ void kernel_updateBuckets(hashElement* d_hashTable, bucket* d_buckets,
		gridParameters rgd_params, int number_of_points)
{
	int ind = blockIdx.x*blockDim.x+threadIdx.x;
	if(ind < number_of_points)
	{
		if(ind == 0)
		{
			int index_of_bucket = d_hashTable[ind].index_of_bucket;
			int index_of_bucket_1 = d_hashTable[ind+1].index_of_bucket;

			d_buckets[index_of_bucket].index_begin=ind;
			if(index_of_bucket != index_of_bucket_1)
			{
				d_buckets[index_of_bucket].index_end=ind+1;
				d_buckets[index_of_bucket_1].index_end=ind+1;
			}
		}else if(ind == number_of_points-1)
		{
			d_buckets[d_hashTable[ind].index_of_bucket].index_end=ind+1;
		}else
		{
			int index_of_bucket = d_hashTable[ind].index_of_bucket;
			int index_of_bucket_1 = d_hashTable[ind+1].index_of_bucket;

			if(index_of_bucket != index_of_bucket_1)
			{
				d_buckets[index_of_bucket].index_end=ind+1;
				d_buckets[index_of_bucket_1].index_begin=ind+1;
			}
		}
	}
}

__global__ void kernel_countNumberOfPointsForBuckets(bucket* d_buckets, gridParameters rgd_params)
{
	int ind=blockIdx.x*blockDim.x+threadIdx.x;
	if(ind < rgd_params.number_of_buckets)
	{
		int index_begin = d_buckets[ind].index_begin;
		int index_end = d_buckets[ind].index_end;

		if(index_begin != -1 && index_end !=-1)
		{
			d_buckets[ind].number_of_points = index_end - index_begin;
		}
	}
}

__global__ void kernel_copyKeys(hashElement* d_hashTable_in, hashElement* d_hashTable_out, int number_of_points)
{
	int ind=blockIdx.x*blockDim.x+threadIdx.x;
	if(ind < number_of_points)
	{
		d_hashTable_out[ind] = d_hashTable_in[ind];
	}
}

cudaError_t cudaCalculateGrid(int threads, pcl::PointNormal *d_point_cloud, bucket *d_buckets,
		hashElement *d_hashTable, int number_of_points, gridParameters rgd_params)
{
	cudaError_t err = cudaGetLastError();
	hashElement* d_temp_hashTable;	cudaMalloc((void**)&d_temp_hashTable,number_of_points*sizeof(hashElement));
	int blocks=number_of_points/threads + 1;
	
	kernel_initializeIndByKey<<<blocks,threads>>>(d_temp_hashTable, number_of_points);
	err = cudaDeviceSynchronize();	if(err != ::cudaSuccess)return err;
	
	kernel_getIndexOfBucketForPoints<<<blocks,threads>>>(d_point_cloud, d_temp_hashTable, number_of_points, rgd_params);
	err = cudaDeviceSynchronize();	if(err != ::cudaSuccess)return err;

	try
	{
		thrust::device_ptr<hashElement> t_d_temp_hashTable(d_temp_hashTable);
		thrust::sort(t_d_temp_hashTable,t_d_temp_hashTable+number_of_points,compareHashElements());
	}
	catch(thrust::system_error &e)	
	{
		err = cudaGetLastError(); 
		return err;
	}	
	catch(std::bad_alloc &e)
	{
		err = cudaGetLastError(); 
		return err;
	}	

	kernel_initializeBuckets<<<rgd_params.number_of_buckets/threads+1,threads>>>(d_buckets,rgd_params);
	err = cudaDeviceSynchronize();	if(err != ::cudaSuccess)return err;
	
	kernel_updateBuckets<<<blocks,threads>>>(d_temp_hashTable, d_buckets, rgd_params, number_of_points);
	err = cudaDeviceSynchronize();	if(err != ::cudaSuccess)return err;
	
	kernel_countNumberOfPointsForBuckets<<<rgd_params.number_of_buckets/threads+1,threads>>>(d_buckets, rgd_params);
	err = cudaDeviceSynchronize();	if(err != ::cudaSuccess)return err;
	
	kernel_copyKeys<<<blocks,threads>>>(d_temp_hashTable, d_hashTable, number_of_points);
	err = cudaDeviceSynchronize(); if(err != ::cudaSuccess)return err;
	
	err = cudaFree(d_temp_hashTable);
	return err;
}

/////////////////////////////////computeNormalVectors/////////////////////////////////////
__global__ void kernel_normalvectorcomputation_step1(
		pcl::PointNormal * d_point_cloud,
		hashElement* d_hashTable,
		simple_point3D* d_mean,
		int number_of_points,
		bucket* d_buckets,
		gridParameters rgd_params,
		float search_radius,
		int max_number_considered_in_INNER_bucket,
		int max_number_considered_in_OUTER_bucket)
{
	int index_of_point = blockIdx.x * blockDim.x + threadIdx.x;

	if(index_of_point < number_of_points)
	{
		d_point_cloud[index_of_point].normal_x = 0;
		d_point_cloud[index_of_point].normal_y = 0;
		d_point_cloud[index_of_point].normal_z = 0;
		__syncthreads();

		float x = d_point_cloud[index_of_point].x;
		float y = d_point_cloud[index_of_point].y;
		float z = d_point_cloud[index_of_point].z;

		if(x < rgd_params.bounding_box_min_X || x > rgd_params.bounding_box_max_X)
		{
			d_mean[index_of_point].x = 0.0f;
			d_mean[index_of_point].y = 0.0f;
			d_mean[index_of_point].z = 0.0f;
			return;
		}
		if(y < rgd_params.bounding_box_min_Y || y > rgd_params.bounding_box_max_Y)
		{
			d_mean[index_of_point].x = 0.0f;
			d_mean[index_of_point].y = 0.0f;
			d_mean[index_of_point].z = 0.0f;
			return;
		}
		if(z < rgd_params.bounding_box_min_Z || z > rgd_params.bounding_box_max_Z)
		{
			d_mean[index_of_point].x = 0.0f;
			d_mean[index_of_point].y = 0.0f;
			d_mean[index_of_point].z = 0.0f;
			return;
		}

		int ix=(x - rgd_params.bounding_box_min_X)/rgd_params.resolution_X;
		int iy=(y - rgd_params.bounding_box_min_Y)/rgd_params.resolution_Y;
		int iz=(z - rgd_params.bounding_box_min_Z)/rgd_params.resolution_Z;

		int index_of_bucket = ix*rgd_params.number_of_buckets_Y *
				rgd_params.number_of_buckets_Z + iy * rgd_params.number_of_buckets_Z + iz;

		if(index_of_bucket >= 0 && index_of_bucket < rgd_params.number_of_buckets)
		{
			int ix = index_of_bucket/(rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z);
			int iy = (index_of_bucket%(rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z))/rgd_params.number_of_buckets_Z;
			int iz = (index_of_bucket%(rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z))%rgd_params.number_of_buckets_Z;

			int sx, sy, sz, stx, sty, stz;
			if(ix == 0) sx = 0; else sx = -1;
			if(iy == 0) sy = 0; else sy = -1;
			if(iz == 0) sz = 0; else sz = -1;

			if(ix == rgd_params.number_of_buckets_X - 1)stx = 1; else stx = 2;
			if(iy == rgd_params.number_of_buckets_Y - 1)sty = 1; else sty = 2;
			if(iz == rgd_params.number_of_buckets_Z - 1)stz = 1; else stz = 2;

			int number_of_nearest_neighbours = 0;
			simple_point3D mean;
			mean.x = 0.0f;
			mean.y = 0.0f;
			mean.z = 0.0f;

			float nearest_neighbour_x;
			float nearest_neighbour_y;
			float nearest_neighbour_z;

			for(int i = sx; i < stx; i++)
			{
				for(int j = sy; j < sty; j++)
				{
					for(int k = sz; k < stz; k++)
					{
						int index_of_neighbour_bucket=index_of_bucket+i*rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z+j*rgd_params.number_of_buckets_Z+k;

						if(index_of_neighbour_bucket >= 0 && index_of_neighbour_bucket < rgd_params.number_of_buckets)
						{
							int iter;
							int number_of_points_in_bucket = d_buckets[index_of_neighbour_bucket].number_of_points;
							if(number_of_points_in_bucket <= 0)continue;

							int max_number_considered_in_bucket;
							if(index_of_neighbour_bucket==index_of_bucket)
							{
								max_number_considered_in_bucket = max_number_considered_in_INNER_bucket;
							}else
							{
								max_number_considered_in_bucket = max_number_considered_in_OUTER_bucket;
							}
							if(max_number_considered_in_bucket <= 0)continue;

							if(max_number_considered_in_bucket >= number_of_points_in_bucket)
							{
								iter=1;
							}else
							{
								iter = number_of_points_in_bucket / max_number_considered_in_bucket;
								if(iter <= 0)iter = 1;
							}

							int l_begin = d_buckets[index_of_neighbour_bucket].index_begin;
							int l_end = d_buckets[index_of_neighbour_bucket].index_end;

							for(int l = l_begin; l < l_end; l += iter)
							{
								if(l >= 0 && l < number_of_points)
								{
									int hashed_index_of_point = d_hashTable[l].index_of_point;
									nearest_neighbour_x = d_point_cloud[hashed_index_of_point].x;
									nearest_neighbour_y = d_point_cloud[hashed_index_of_point].y;
									nearest_neighbour_z = d_point_cloud[hashed_index_of_point].z;

									float dist=sqrtf((x - nearest_neighbour_x)*(x - nearest_neighbour_x)
													+(y - nearest_neighbour_y)*(y - nearest_neighbour_y)
													+(z - nearest_neighbour_z)*(z - nearest_neighbour_z));

									if(dist <= search_radius)
									{
										mean.x += nearest_neighbour_x;
										mean.y += nearest_neighbour_y;
										mean.z += nearest_neighbour_z;
										number_of_nearest_neighbours++;
									}
								}
							}
						}
					}
				}
			}

			if(number_of_nearest_neighbours >= 3)
			{
				d_mean[index_of_point].x = mean.x / number_of_nearest_neighbours;
				d_mean[index_of_point].y = mean.y / number_of_nearest_neighbours;
				d_mean[index_of_point].z = mean.z / number_of_nearest_neighbours;
			}else
			{
				d_mean[index_of_point].x = 0.0f;
				d_mean[index_of_point].y = 0.0f;
				d_mean[index_of_point].z = 0.0f;
			}
		}
	}
}

__global__ void kernel_normalvectorcomputation_step2(
	pcl::PointNormal *d_point_cloud,
	hashElement *d_hashTable,
	simple_point3D *d_mean,
	int number_of_points,
	bucket *d_buckets,
	gridParameters rgd_params,
	float search_radius,
	int max_number_considered_in_INNER_bucket,
	int max_number_considered_in_OUTER_bucket)
{
	int index_of_point = blockIdx.x * blockDim.x + threadIdx.x;
	if(index_of_point < number_of_points)
	{
		float x = d_point_cloud[index_of_point].x;
		float y = d_point_cloud[index_of_point].y;
		float z = d_point_cloud[index_of_point].z;

		if(x < rgd_params.bounding_box_min_X || x > rgd_params.bounding_box_max_X)
		{
			d_point_cloud[index_of_point].normal_x = 0.0f;
			d_point_cloud[index_of_point].normal_y = 0.0f;
			d_point_cloud[index_of_point].normal_z = 0.0f;
			d_point_cloud[index_of_point].curvature = 0.0f;
			return;
		}
		if(y < rgd_params.bounding_box_min_Y || y > rgd_params.bounding_box_max_Y)
		{
			d_point_cloud[index_of_point].normal_x = 0.0f;
			d_point_cloud[index_of_point].normal_y = 0.0f;
			d_point_cloud[index_of_point].normal_z = 0.0f;
			d_point_cloud[index_of_point].curvature = 0.0f;
			return;
		}
		if(z < rgd_params.bounding_box_min_Z || z > rgd_params.bounding_box_max_Z)
		{
			d_point_cloud[index_of_point].normal_x = 0.0f;
			d_point_cloud[index_of_point].normal_y = 0.0f;
			d_point_cloud[index_of_point].normal_z = 0.0f;
			d_point_cloud[index_of_point].curvature = 0.0f;
			return;
		}

		int ix=(x - rgd_params.bounding_box_min_X)/rgd_params.resolution_X;
		int iy=(y - rgd_params.bounding_box_min_Y)/rgd_params.resolution_Y;
		int iz=(z - rgd_params.bounding_box_min_Z)/rgd_params.resolution_Z;

		int index_of_bucket = ix*rgd_params.number_of_buckets_Y *
				rgd_params.number_of_buckets_Z + iy * rgd_params.number_of_buckets_Z + iz;



		if(index_of_bucket >= 0 && index_of_bucket < rgd_params.number_of_buckets)
		{
			simple_point3D mean = d_mean[index_of_point];
			if(mean.x != 0.0f && mean.y != 0.0f && mean.z != 0.0f)
			{
				int ix = index_of_bucket/(rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z);
				int iy = (index_of_bucket%(rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z))/rgd_params.number_of_buckets_Z;
				int iz = (index_of_bucket%(rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z))%rgd_params.number_of_buckets_Z;
				int sx, sy, sz, stx, sty, stz;
				if(ix == 0)sx = 0; else sx = -1;
				if(iy == 0)sy = 0; else sy = -1;
				if(iz == 0)sz = 0; else sz = -1;
				if(ix == rgd_params.number_of_buckets_X - 1)stx = 1; else stx = 2;
				if(iy == rgd_params.number_of_buckets_Y - 1)sty = 1; else sty = 2;
				if(iz == rgd_params.number_of_buckets_Z - 1)stz = 1; else stz = 2;

				int number_of_nearest_neighbours=0;

				double cov[3][3];
				cov[0][0]=cov[0][1]=cov[0][2]=cov[1][0]=cov[1][1]=cov[1][2]=cov[2][0]=cov[2][1]=cov[2][2]=0;

				float nearest_neighbour_x;
				float nearest_neighbour_y;
				float nearest_neighbour_z;

				for(int i = sx; i < stx; i++)
				{
					for(int j = sy; j < sty; j++)
					{
						for(int k = sz; k < stz; k++)
						{
							int index_of_neighbour_bucket=index_of_bucket+i*rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z+j*rgd_params.number_of_buckets_Z+k;
							if(index_of_neighbour_bucket >= 0 && index_of_neighbour_bucket < rgd_params.number_of_buckets)
							{
								int iter;
								int number_of_points_in_bucket = d_buckets[index_of_neighbour_bucket].number_of_points;
								if(number_of_points_in_bucket <= 0)continue;

								int max_number_considered_in_bucket;
								if(index_of_neighbour_bucket==index_of_bucket)
								{
									max_number_considered_in_bucket = max_number_considered_in_INNER_bucket;
								}else
								{
									max_number_considered_in_bucket = max_number_considered_in_OUTER_bucket;
								}
								if(max_number_considered_in_bucket <= 0)continue;


								if(max_number_considered_in_bucket >= number_of_points_in_bucket)
								{
									iter=1;
								}else
								{
									iter = number_of_points_in_bucket / max_number_considered_in_bucket;
									if(iter <= 0)iter = 1;
								}

								int l_begin = d_buckets[index_of_neighbour_bucket].index_begin;
								int l_end = d_buckets[index_of_neighbour_bucket].index_end;

								for(int l = l_begin; l < l_end; l += iter)
								{
									if(l >= 0 && l < number_of_points)
									{
										int hashed_index_of_point = d_hashTable[l].index_of_point;
										nearest_neighbour_x = d_point_cloud[hashed_index_of_point].x;
										nearest_neighbour_y = d_point_cloud[hashed_index_of_point].y;
										nearest_neighbour_z = d_point_cloud[hashed_index_of_point].z;

										float dist = sqrtf((x - nearest_neighbour_x)*(x - nearest_neighbour_x)
														  +(y - nearest_neighbour_y)*(y - nearest_neighbour_y)
														  +(z - nearest_neighbour_z)*(z - nearest_neighbour_z));

										if(dist <= search_radius)
										{
											cov[0][0]+=(mean.x - nearest_neighbour_x) * (mean.x - nearest_neighbour_x);
											cov[0][1]+=(mean.x - nearest_neighbour_x) * (mean.y - nearest_neighbour_y);
											cov[0][2]+=(mean.x - nearest_neighbour_x) * (mean.z - nearest_neighbour_z);
											cov[1][0]+=(mean.y - nearest_neighbour_y) * (mean.x - nearest_neighbour_x);
											cov[1][1]+=(mean.y - nearest_neighbour_y) * (mean.y - nearest_neighbour_y);
											cov[1][2]+=(mean.y - nearest_neighbour_y) * (mean.z - nearest_neighbour_z);
											cov[2][0]+=(mean.z - nearest_neighbour_z) * (mean.x - nearest_neighbour_x);
											cov[2][1]+=(mean.z - nearest_neighbour_z) * (mean.y - nearest_neighbour_y);
											cov[2][2]+=(mean.z - nearest_neighbour_z) * (mean.z - nearest_neighbour_z);
											number_of_nearest_neighbours++;
										}
									}
								}
							}
						}
					}
				}

				if(number_of_nearest_neighbours >= 3)
				{
					cov[0][0]/=number_of_nearest_neighbours;
					cov[0][1]/=number_of_nearest_neighbours;
					cov[0][2]/=number_of_nearest_neighbours;
					cov[1][0]/=number_of_nearest_neighbours;
					cov[1][1]/=number_of_nearest_neighbours;
					cov[1][2]/=number_of_nearest_neighbours;
					cov[2][0]/=number_of_nearest_neighbours;
					cov[2][1]/=number_of_nearest_neighbours;
					cov[2][2]/=number_of_nearest_neighbours;

					double U[3][3], V[3][3];
					double SS[9];
					gpuSVD((double *)cov, (double *)U, (double *)SS, (double *)V);
					double _nx = (float)(U[0][1]*U[1][2] - U[0][2]*U[1][1]);
					double _ny = (float)(-(U[0][0]*U[1][2] - U[0][2]*U[1][0] ));
					double _nz = (float)(U[0][0]*U[1][1] - U[0][1]*U[1][0]);

					double lenght = sqrt(_nx*_nx + _ny*_ny + _nz*_nz);
					if(lenght==0)
					{
						d_point_cloud[index_of_point].normal_x = 0.0f;
						d_point_cloud[index_of_point].normal_y = 0.0f;
						d_point_cloud[index_of_point].normal_z = 0.0f;
						d_point_cloud[index_of_point].curvature = 0.0f;
					}else
					{
						d_point_cloud[index_of_point].normal_x = _nx/lenght;
						d_point_cloud[index_of_point].normal_y = _ny/lenght;
						d_point_cloud[index_of_point].normal_z = _nz/lenght;
						d_point_cloud[index_of_point].curvature = SS[0]/(SS[0] + SS[4] + SS[8]);
					}
				}
				else
				{
					d_point_cloud[index_of_point].normal_x = 0.0f;
					d_point_cloud[index_of_point].normal_y = 0.0f;
					d_point_cloud[index_of_point].normal_z = 0.0f;
					d_point_cloud[index_of_point].curvature = 0.0f;
				}
			}
		}
	}
}

__global__ void kernel_normalvectorcomputation_step1_fast(
		pcl::PointNormal * d_point_cloud,
		hashElement* d_hashTable,
		simple_point3D* d_mean,
		int number_of_points,
		bucket* d_buckets, 
		gridParameters rgd_params,
		float search_radius, 
		int max_number_considered_in_INNER_bucket, 
		int max_number_considered_in_OUTER_bucket)
{
	int index_of_point = blockIdx.x * blockDim.x + threadIdx.x;

	if(index_of_point < number_of_points)
	{
		d_point_cloud[index_of_point].normal_x = 0;
		d_point_cloud[index_of_point].normal_y = 0;
		d_point_cloud[index_of_point].normal_z = 0;
		__syncthreads();

		int index_of_bucket = d_hashTable[index_of_point].index_of_bucket;
		
		if(index_of_bucket >= 0 && index_of_bucket < rgd_params.number_of_buckets)
		{
			int hashed_index_of_point = d_hashTable[index_of_point].index_of_point;

			if(hashed_index_of_point >= 0 && hashed_index_of_point < number_of_points)
			{
				float x = d_point_cloud[hashed_index_of_point].x;
				float y = d_point_cloud[hashed_index_of_point].y;
				float z = d_point_cloud[hashed_index_of_point].z;

				int ix = index_of_bucket/(rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z);
				int iy = (index_of_bucket%(rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z))/rgd_params.number_of_buckets_Z;
				int iz = (index_of_bucket%(rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z))%rgd_params.number_of_buckets_Z;

				int sx, sy, sz, stx, sty, stz;
				if(ix == 0) sx = 0; else sx = -1;
				if(iy == 0) sy = 0; else sy = -1;
				if(iz == 0) sz = 0; else sz = -1;

				if(ix == rgd_params.number_of_buckets_X - 1)stx = 1; else stx = 2;
				if(iy == rgd_params.number_of_buckets_Y - 1)sty = 1; else sty = 2;
				if(iz == rgd_params.number_of_buckets_Z - 1)stz = 1; else stz = 2;

				int number_of_nearest_neighbours = 0;
				simple_point3D mean;
				mean.x = 0.0f;
				mean.y = 0.0f;
				mean.z = 0.0f;

				float nearest_neighbour_x;
				float nearest_neighbour_y;
				float nearest_neighbour_z;
			
				for(int i = sx; i < stx; i++)
				{
					for(int j = sy; j < sty; j++)
					{
						for(int k = sz; k < stz; k++)
						{
							int index_of_neighbour_bucket=index_of_bucket+i*rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z+j*rgd_params.number_of_buckets_Z+k;

							if(index_of_neighbour_bucket >= 0 && index_of_neighbour_bucket < rgd_params.number_of_buckets)
							{
								int iter;
								int number_of_points_in_bucket = d_buckets[index_of_neighbour_bucket].number_of_points;
								if(number_of_points_in_bucket <= 0)continue;

								int max_number_considered_in_bucket;
								if(index_of_neighbour_bucket==index_of_bucket)
								{
									max_number_considered_in_bucket = max_number_considered_in_INNER_bucket;
								}else
								{
									max_number_considered_in_bucket = max_number_considered_in_OUTER_bucket;
								}
								if(max_number_considered_in_bucket <= 0)continue;

								if(max_number_considered_in_bucket >= number_of_points_in_bucket)
								{
									iter=1;
								}else
								{
									iter = number_of_points_in_bucket / max_number_considered_in_bucket;
									if(iter <= 0)iter = 1;
								}

								int l_begin = d_buckets[index_of_neighbour_bucket].index_begin;
								int l_end = d_buckets[index_of_neighbour_bucket].index_end;

								for(int l = l_begin; l < l_end; l += iter)
								{
									if(l >= 0 && l < number_of_points)
									{
										int indexNextPointInBucket = d_hashTable[l].index_of_point;
										nearest_neighbour_x = d_point_cloud[indexNextPointInBucket].x;
										nearest_neighbour_y = d_point_cloud[indexNextPointInBucket].y;
										nearest_neighbour_z = d_point_cloud[indexNextPointInBucket].z;

										float dist=sqrtf((x - nearest_neighbour_x)*(x - nearest_neighbour_x)
														+(y - nearest_neighbour_y)*(y - nearest_neighbour_y)
														+(z - nearest_neighbour_z)*(z - nearest_neighbour_z));

										if(dist <= search_radius)
										{
											mean.x += nearest_neighbour_x;
											mean.y += nearest_neighbour_y;
											mean.z += nearest_neighbour_z;
											number_of_nearest_neighbours++;
										}
									}
								}
							}
						}
					}
				}
				
				if(number_of_nearest_neighbours >= 3)
				{
					d_mean[index_of_point].x = mean.x / number_of_nearest_neighbours;
					d_mean[index_of_point].y = mean.y / number_of_nearest_neighbours;
					d_mean[index_of_point].z = mean.z / number_of_nearest_neighbours;
				}else
				{
					d_mean[index_of_point].x = 0.0f;
					d_mean[index_of_point].y = 0.0f;
					d_mean[index_of_point].z = 0.0f;
				}
			}
		}
	}
}

__global__ void kernel_normalvectorcomputation_step2_fast(
	pcl::PointNormal *d_point_cloud,
	hashElement *d_hashTable,
	simple_point3D *d_mean,
	int number_of_points,
	bucket *d_buckets,
	gridParameters rgd_params,
	float search_radius, 
	int max_number_considered_in_INNER_bucket, 
	int max_number_considered_in_OUTER_bucket)
{
	int index_of_point = blockIdx.x * blockDim.x + threadIdx.x;
	if(index_of_point < number_of_points)
	{
		int index_of_bucket = d_hashTable[index_of_point].index_of_bucket;
		if(index_of_bucket >= 0 && index_of_bucket < rgd_params.number_of_buckets)
		{
			int hashed_index_of_point = d_hashTable[index_of_point].index_of_point;
			if(hashed_index_of_point >= 0 && hashed_index_of_point < number_of_points)
			{
				simple_point3D mean = d_mean[index_of_point];
				if(mean.x != 0.0f && mean.y != 0.0f && mean.z != 0.0f)
				{
					float x = d_point_cloud[hashed_index_of_point].x;
					float y = d_point_cloud[hashed_index_of_point].y;
					float z = d_point_cloud[hashed_index_of_point].z;

					int ix = index_of_bucket/(rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z);
					int iy = (index_of_bucket%(rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z))/rgd_params.number_of_buckets_Z;
					int iz = (index_of_bucket%(rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z))%rgd_params.number_of_buckets_Z;
					int sx, sy, sz, stx, sty, stz;
					if(ix == 0)sx = 0; else sx = -1;
					if(iy == 0)sy = 0; else sy = -1;
					if(iz == 0)sz = 0; else sz = -1;
					if(ix == rgd_params.number_of_buckets_X - 1)stx = 1; else stx = 2;
					if(iy == rgd_params.number_of_buckets_Y - 1)sty = 1; else sty = 2;
					if(iz == rgd_params.number_of_buckets_Z - 1)stz = 1; else stz = 2;

					int number_of_nearest_neighbours=0;

					double cov[3][3];
					cov[0][0]=cov[0][1]=cov[0][2]=cov[1][0]=cov[1][1]=cov[1][2]=cov[2][0]=cov[2][1]=cov[2][2]=0;

					float nearest_neighbour_x;
					float nearest_neighbour_y;
					float nearest_neighbour_z;
					
					for(int i = sx; i < stx; i++)
					{
						for(int j = sy; j < sty; j++)
						{
							for(int k = sz; k < stz; k++)
							{
								int index_of_neighbour_bucket=index_of_bucket+i*rgd_params.number_of_buckets_Y*rgd_params.number_of_buckets_Z+j*rgd_params.number_of_buckets_Z+k;
								if(index_of_neighbour_bucket >= 0 && index_of_neighbour_bucket < rgd_params.number_of_buckets)
								{
									int iter;
									int number_of_points_in_bucket = d_buckets[index_of_neighbour_bucket].number_of_points;
									if(number_of_points_in_bucket <= 0)continue;

									int max_number_considered_in_bucket;
									if(index_of_neighbour_bucket==index_of_bucket)
									{
										max_number_considered_in_bucket = max_number_considered_in_INNER_bucket;
									}else
									{
										max_number_considered_in_bucket = max_number_considered_in_OUTER_bucket;
									}
									if(max_number_considered_in_bucket <= 0)continue;


									if(max_number_considered_in_bucket >= number_of_points_in_bucket)
									{
										iter=1;
									}else
									{
										iter = number_of_points_in_bucket / max_number_considered_in_bucket;
										if(iter <= 0)iter = 1;
									}

									int l_begin = d_buckets[index_of_neighbour_bucket].index_begin;
									int l_end = d_buckets[index_of_neighbour_bucket].index_end;

									for(int l = l_begin; l < l_end; l += iter)
									{
										if(l >= 0 && l < number_of_points)
										{
											int indexNextPointInBucket = d_hashTable[l].index_of_point;
											nearest_neighbour_x = d_point_cloud[indexNextPointInBucket].x;
											nearest_neighbour_y = d_point_cloud[indexNextPointInBucket].y;
											nearest_neighbour_z = d_point_cloud[indexNextPointInBucket].z;

											float dist = sqrtf((x - nearest_neighbour_x)*(x - nearest_neighbour_x)
															  +(y - nearest_neighbour_y)*(y - nearest_neighbour_y)
   															  +(z - nearest_neighbour_z)*(z - nearest_neighbour_z));

											if(dist <= search_radius)
											{
												cov[0][0]+=(mean.x - nearest_neighbour_x) * (mean.x - nearest_neighbour_x);
												cov[0][1]+=(mean.x - nearest_neighbour_x) * (mean.y - nearest_neighbour_y);
												cov[0][2]+=(mean.x - nearest_neighbour_x) * (mean.z - nearest_neighbour_z);
												cov[1][0]+=(mean.y - nearest_neighbour_y) * (mean.x - nearest_neighbour_x);
												cov[1][1]+=(mean.y - nearest_neighbour_y) * (mean.y - nearest_neighbour_y);
												cov[1][2]+=(mean.y - nearest_neighbour_y) * (mean.z - nearest_neighbour_z);
												cov[2][0]+=(mean.z - nearest_neighbour_z) * (mean.x - nearest_neighbour_x);
												cov[2][1]+=(mean.z - nearest_neighbour_z) * (mean.y - nearest_neighbour_y);
												cov[2][2]+=(mean.z - nearest_neighbour_z) * (mean.z - nearest_neighbour_z);
												number_of_nearest_neighbours++;
											}
										}
									}
								}
							}
						}
					}

					if(number_of_nearest_neighbours >= 3)
					{
						cov[0][0]/=number_of_nearest_neighbours;
						cov[0][1]/=number_of_nearest_neighbours;
						cov[0][2]/=number_of_nearest_neighbours;
						cov[1][0]/=number_of_nearest_neighbours;
						cov[1][1]/=number_of_nearest_neighbours;
						cov[1][2]/=number_of_nearest_neighbours;
						cov[2][0]/=number_of_nearest_neighbours;
						cov[2][1]/=number_of_nearest_neighbours;
						cov[2][2]/=number_of_nearest_neighbours;

						double U[3][3], V[3][3];
						double SS[9];
						gpuSVD((double *)cov, (double *)U, (double *)SS, (double *)V);
						double _nx = (float)(U[0][1]*U[1][2] - U[0][2]*U[1][1]);
						double _ny = (float)(-(U[0][0]*U[1][2] - U[0][2]*U[1][0] ));
						double _nz = (float)(U[0][0]*U[1][1] - U[0][1]*U[1][0]);

						double lenght = sqrt(_nx*_nx + _ny*_ny + _nz*_nz);
						if(lenght==0)
						{
							d_point_cloud[hashed_index_of_point].normal_x = 0.0f;
							d_point_cloud[hashed_index_of_point].normal_y = 0.0f;
							d_point_cloud[hashed_index_of_point].normal_z = 0.0f;
							d_point_cloud[hashed_index_of_point].curvature = 0.0f;
						}else
						{
							d_point_cloud[hashed_index_of_point].normal_x = _nx/lenght;
							d_point_cloud[hashed_index_of_point].normal_y = _ny/lenght;
							d_point_cloud[hashed_index_of_point].normal_z = _nz/lenght;
							d_point_cloud[hashed_index_of_point].curvature = SS[0]/(SS[0] + SS[4] + SS[8]);
						}
					}
					else
					{
						d_point_cloud[hashed_index_of_point].normal_x = 0.0f;
						d_point_cloud[hashed_index_of_point].normal_y = 0.0f;
						d_point_cloud[hashed_index_of_point].normal_z = 0.0f;
						d_point_cloud[hashed_index_of_point].curvature = 0.0f;
					}
				}
			}
		}
	}
}


cudaError_t cudaCalculateNormalVectors(
	int threads,
	pcl::PointNormal * d_point_cloud,
	int number_of_points,
	hashElement* d_hashTable,
	bucket* d_buckets,
	simple_point3D* d_mean,
	gridParameters rgd_params,
	float search_radius,
	int max_number_considered_in_INNER_bucket,
	int max_number_considered_in_OUTER_bucket)
{
	cudaError_t err = cudaGetLastError();
	
	int blocks=number_of_points/threads+1;

	kernel_normalvectorcomputation_step1<<<blocks,threads>>>(
		d_point_cloud,
		d_hashTable,
		d_mean,
		number_of_points,
		d_buckets,
		rgd_params,
		search_radius,
		max_number_considered_in_INNER_bucket,
		max_number_considered_in_OUTER_bucket);
	err = cudaDeviceSynchronize();
	if(err != ::cudaSuccess)return err;

	kernel_normalvectorcomputation_step2<<<blocks,threads>>>(
		d_point_cloud,
		d_hashTable,
		d_mean,
		number_of_points,
		d_buckets,
		rgd_params,
		search_radius,
		max_number_considered_in_INNER_bucket,
		max_number_considered_in_OUTER_bucket);
	err = cudaDeviceSynchronize();

	return err;
}

cudaError_t cudaCalculateNormalVectorsFast(
	int threads,
	pcl::PointNormal * d_point_cloud,
	int number_of_points,
	hashElement* d_hashTable,
	bucket* d_buckets,
	simple_point3D* d_mean,
	gridParameters rgd_params,
	float search_radius,
	int max_number_considered_in_INNER_bucket,
	int max_number_considered_in_OUTER_bucket)
{
	cudaError_t err = cudaGetLastError();

	int blocks=number_of_points/threads+1;

	kernel_normalvectorcomputation_step1_fast<<<blocks,threads>>>(
		d_point_cloud, 
		d_hashTable,
		d_mean,
		number_of_points,
		d_buckets, 
		rgd_params,
		search_radius, 
		max_number_considered_in_INNER_bucket, 
		max_number_considered_in_OUTER_bucket);
	err = cudaDeviceSynchronize();
	if(err != ::cudaSuccess)return err;

	kernel_normalvectorcomputation_step2_fast<<<blocks,threads>>>(
		d_point_cloud, 
		d_hashTable,
		d_mean,
		number_of_points,
		d_buckets,
		rgd_params,
		search_radius, 
		max_number_considered_in_INNER_bucket, 
		max_number_considered_in_OUTER_bucket);
	err = cudaDeviceSynchronize();
	
	return err;
}

__global__ void kernel_flipNormalsTowardsViewpoint(
	pcl::PointNormal * d_point_cloud, 
	int number_of_points, 
	float viepoint_X, 
	float viepoint_Y, 
	float viepoint_Z)
{
	int index_of_point=blockIdx.x*blockDim.x+threadIdx.x;
	if(index_of_point<number_of_points)
	{
		pcl::PointNormal p = d_point_cloud[index_of_point];
		if(p.normal_x * (viepoint_X - p.x) + p.normal_y * (viepoint_Y - p.y) + p.normal_z * (viepoint_Z - p.z)  < 0.0)
		{
			d_point_cloud[index_of_point].normal_x = -p.normal_x;
			d_point_cloud[index_of_point].normal_y = -p.normal_y;
			d_point_cloud[index_of_point].normal_z = -p.normal_z;
		}
	}
}

cudaError_t cudaFlipNormalsTowardsViewpoint(
	int threads,
	pcl::PointNormal * d_point_cloud, 
	int number_of_points, 
	float viepoint_X, 
	float viepoint_Y, 
	float viepoint_Z)
{
	cudaError_t err = cudaGetLastError();
	
	int blocks=number_of_points/threads+1;
	kernel_flipNormalsTowardsViewpoint<<<blocks,threads>>>(
		d_point_cloud, 
		number_of_points, 
		viepoint_X, 
		viepoint_Y, 
		viepoint_Z);
	err = cudaDeviceSynchronize();

	return err;
}

