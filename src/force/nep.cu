/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, Mikko Ervasti, and Ari Harju
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/

/*----------------------------------------------------------------------------80
The neuroevolution potential (NEP)
Ref: Zheyong Fan et al., in preparation.
------------------------------------------------------------------------------*/

#include "nep.cuh"
#include "utilities/error.cuh"
#include "utilities/nep_utilities.cuh"
#include <vector>

const int MAX_NUM_NEURONS_PER_LAYER = 50; // largest ANN: input-50-50-output
const int MAX_NUM_N = 13;                 // n_max+1 = 12+1
const int MAX_NUM_L = 7;                  // L_max+1 = 6+1
const int MAX_DIM = MAX_NUM_N * MAX_NUM_L;
__constant__ float c_parameters[10000];

static void read_atomic_number(char* input_dir, GPU_Vector<float>& atomic_number)
{
  std::vector<float> atomic_number_cpu(atomic_number.size());
  char file_atomic_number[200];
  strcpy(file_atomic_number, input_dir);
  strcat(file_atomic_number, "/atomic_number.in");
  FILE* fid_atomic_number = my_fopen(file_atomic_number, "r");
  for (int n = 0; n < atomic_number.size(); ++n) {
    int count = fscanf(fid_atomic_number, "%f", &atomic_number_cpu[n]);
    PRINT_SCANF_ERROR(count, 1, "reading error for atomic_number.in.");
  }
  fclose(fid_atomic_number);

  float max_atomic_number = -1;
  for (int n = 0; n < atomic_number.size(); ++n) {
    if (max_atomic_number < atomic_number_cpu[n]) {
      max_atomic_number = atomic_number_cpu[n];
    }
  }
  for (int n = 0; n < atomic_number.size(); ++n) {
    atomic_number_cpu[n] = sqrt(atomic_number_cpu[n] / max_atomic_number);
  }

  atomic_number.copy_from_host(atomic_number_cpu.data());
}

NEP2::NEP2(FILE* fid, char* input_dir, const Neighbor& neighbor)
{
  printf("Use the NEP potential.\n");
  char name[20];

  int count = fscanf(fid, "%s%f%f", name, &paramb.rc_radial, &paramb.rc_angular);
  PRINT_SCANF_ERROR(count, 3, "reading error for NEP potential.");
  printf("    radial cutoff = %g A.\n", paramb.rc_radial);
  printf("    angular cutoff = %g A.\n", paramb.rc_angular);

  count = fscanf(fid, "%s%d%d", name, &paramb.n_max_radial, &paramb.n_max_angular);
  PRINT_SCANF_ERROR(count, 3, "reading error for NEP potential.");
  printf("    n_max_radial = %d.\n", paramb.n_max_radial);
  printf("    n_max_angular = %d.\n", paramb.n_max_angular);

  count = fscanf(fid, "%s%d", name, &paramb.L_max);
  PRINT_SCANF_ERROR(count, 2, "reading error for NEP potential.");
  printf("    l_max = %d.\n", paramb.L_max);

  count = fscanf(fid, "%s%d%d", name, &annmb.num_neurons1, &annmb.num_neurons2);
  PRINT_SCANF_ERROR(count, 3, "reading error for NEP potential.");

  rc = paramb.rc_radial; // largest cutoff

  paramb.rcinv_radial = 1.0f / paramb.rc_radial;
  paramb.rcinv_angular = 1.0f / paramb.rc_angular;
  annmb.dim = (paramb.n_max_radial + 1) + (paramb.n_max_angular + 1) * paramb.L_max;

  if (annmb.num_neurons2 == 0) {
    printf("    ANN = %d-%d-1.\n", annmb.dim, annmb.num_neurons1);
  } else {
    printf("    ANN = %d-%d-%d-1.\n", annmb.dim, annmb.num_neurons1, annmb.num_neurons2);
  }

  annmb.num_para = (annmb.dim + 1) * annmb.num_neurons1;
  annmb.num_para += (annmb.num_neurons1 + 1) * annmb.num_neurons2;
  annmb.num_para += (annmb.num_neurons2 == 0 ? annmb.num_neurons1 : annmb.num_neurons2) + 1;

  nep_data.f12x.resize(neighbor.NN.size() * neighbor.MN);
  nep_data.f12y.resize(neighbor.NN.size() * neighbor.MN);
  nep_data.f12z.resize(neighbor.NN.size() * neighbor.MN);
  nep_data.NN.resize(neighbor.NN.size());
  nep_data.NL.resize(neighbor.NN.size() * neighbor.MN);
  nep_data.Fp.resize(neighbor.NN.size() * annmb.dim);
  nep_data.atomic_number.resize(neighbor.NN.size());

  update_potential(fid);
  read_atomic_number(input_dir, nep_data.atomic_number);
}

NEP2::~NEP2(void)
{
  // nothing
}

void NEP2::update_potential(const float* parameters, ANN& ann)
{
  ann.w0 = parameters;
  ann.b0 = ann.w0 + ann.num_neurons1 * ann.dim;
  ann.w1 = ann.b0 + ann.num_neurons1;
  if (ann.num_neurons2 == 0) {
    ann.b1 = ann.w1 + ann.num_neurons1;
  } else {
    ann.b1 = ann.w1 + ann.num_neurons1 * ann.num_neurons2;
    ann.w2 = ann.b1 + ann.num_neurons2;
    ann.b2 = ann.w2 + ann.num_neurons2;
  }
}

void NEP2::update_potential(FILE* fid)
{
  std::vector<float> parameters(annmb.num_para);
  for (int n = 0; n < annmb.num_para; ++n) {
    int count = fscanf(fid, "%f", &parameters[n]);
    PRINT_SCANF_ERROR(count, 1, "reading error for NEP potential.");
  }
  CHECK(cudaMemcpyToSymbol(c_parameters, parameters.data(), sizeof(float) * annmb.num_para));
  float* address_c_parameters;
  CHECK(cudaGetSymbolAddress((void**)&address_c_parameters, c_parameters));
  update_potential(address_c_parameters, annmb);

  for (int d = 0; d < annmb.dim; ++d) {
    int count = fscanf(fid, "%f%f", &paramb.q_scaler[d], &paramb.q_min[d]);
    PRINT_SCANF_ERROR(count, 2, "reading error for NEP potential.");
  }
}

static __device__ void
apply_ann_one_layer(const NEP2::ANN& ann, float* q, float& energy, float* energy_derivative)
{
  for (int n = 0; n < ann.num_neurons1; ++n) {
    float w0_times_q = 0.0f;
    for (int d = 0; d < ann.dim; ++d) {
      w0_times_q += ann.w0[n * ann.dim + d] * q[d];
    }
    float x1 = tanh(w0_times_q - ann.b0[n]);
    energy += ann.w1[n] * x1;
    for (int d = 0; d < ann.dim; ++d) {
      float y1 = (1.0f - x1 * x1) * ann.w0[n * ann.dim + d];
      energy_derivative[d] += ann.w1[n] * y1;
    }
  }
  energy -= ann.b1[0];
}

static __device__ void
apply_ann(const NEP2::ANN& ann, float* q, float& energy, float* energy_derivative)
{
  // energy
  float x1[MAX_NUM_NEURONS_PER_LAYER] = {0.0f}; // states of the 1st hidden layer neurons
  float x2[MAX_NUM_NEURONS_PER_LAYER] = {0.0f}; // states of the 2nd hidden layer neurons
  for (int n = 0; n < ann.num_neurons1; ++n) {
    float w0_times_q = 0.0f;
    for (int d = 0; d < ann.dim; ++d) {
      w0_times_q += ann.w0[n * ann.dim + d] * q[d];
    }
    x1[n] = tanh(w0_times_q - ann.b0[n]);
  }
  for (int n = 0; n < ann.num_neurons2; ++n) {
    for (int m = 0; m < ann.num_neurons1; ++m) {
      x2[n] += ann.w1[n * ann.num_neurons1 + m] * x1[m];
    }
    x2[n] = tanh(x2[n] - ann.b1[n]);
    energy += ann.w2[n] * x2[n];
  }
  energy -= ann.b2[0];
  // energy gradient (compute it component by component)
  for (int d = 0; d < ann.dim; ++d) {
    float y2[MAX_NUM_NEURONS_PER_LAYER] = {0.0f};
    for (int n1 = 0; n1 < ann.num_neurons1; ++n1) {
      float y1 = (1.0f - x1[n1] * x1[n1]) * ann.w0[n1 * ann.dim + d];
      for (int n2 = 0; n2 < ann.num_neurons2; ++n2) {
        y2[n2] += ann.w1[n2 * ann.num_neurons1 + n1] * y1;
      }
    }
    for (int n2 = 0; n2 < ann.num_neurons2; ++n2) {
      energy_derivative[d] += ann.w2[n2] * (y2[n2] * (1.0f - x2[n2] * x2[n2]));
    }
  }
}

static __global__ void find_neighbor_angular(
  NEP2::ParaMB paramb,
  const int N,
  const int N1,
  const int N2,
  const Box box,
  const int* g_NN,
  const int* g_NL,
  const double* __restrict__ g_x,
  const double* __restrict__ g_y,
  const double* __restrict__ g_z,
  int* g_NN_angular,
  int* g_NL_angular)
{
  int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1;
  if (n1 < N2) {
    double x1 = g_x[n1];
    double y1 = g_y[n1];
    double z1 = g_z[n1];
    int count = 0;
    for (int i1 = 0; i1 < g_NN[n1]; ++i1) {
      int n2 = g_NL[n1 + N * i1];
      double x12double = g_x[n2] - x1;
      double y12double = g_y[n2] - y1;
      double z12double = g_z[n2] - z1;
      apply_mic(box, x12double, y12double, z12double);
      float x12 = float(x12double), y12 = float(y12double), z12 = float(z12double);
      float d12sq = x12 * x12 + y12 * y12 + z12 * z12;
      if (d12sq < paramb.rc_angular * paramb.rc_angular) {
        g_NL_angular[count++ * N + n1] = n2;
      }
    }
    g_NN_angular[n1] = count;
  }
}

static __global__ void find_descriptor(
  NEP2::ParaMB paramb,
  NEP2::ANN annmb,
  const int N,
  const int N1,
  const int N2,
  const Box box,
  const int* g_NN,
  const int* g_NL,
  const int* g_NN_angular,
  const int* g_NL_angular,
  const float* __restrict__ g_atomic_number,
  const double* __restrict__ g_x,
  const double* __restrict__ g_y,
  const double* __restrict__ g_z,
  double* g_pe,
  float* g_Fp)
{
  int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1;
  if (n1 < N2) {
    float atomic_number_n1 = g_atomic_number[n1];
    double x1 = g_x[n1];
    double y1 = g_y[n1];
    double z1 = g_z[n1];
    float q[MAX_DIM] = {0.0f};

    // get radial descriptors
    for (int i1 = 0; i1 < g_NN[n1]; ++i1) {
      int n2 = g_NL[n1 + N * i1];
      double x12double = g_x[n2] - x1;
      double y12double = g_y[n2] - y1;
      double z12double = g_z[n2] - z1;
      apply_mic(box, x12double, y12double, z12double);
      float x12 = float(x12double), y12 = float(y12double), z12 = float(z12double);
      float d12 = sqrt(x12 * x12 + y12 * y12 + z12 * z12);
      float fc12;
      find_fc(paramb.rc_radial, paramb.rcinv_radial, d12, fc12);
      fc12 *= atomic_number_n1 * g_atomic_number[n2];
      float fn12[MAX_NUM_N];
      find_fn(paramb.n_max_radial, paramb.rcinv_radial, d12, fc12, fn12);
      for (int n = 0; n <= paramb.n_max_radial; ++n) {
        q[n] += fn12[n];
      }
    }

    // get angular descriptors
    for (int i1 = 0; i1 < g_NN_angular[n1]; ++i1) {
      int n2 = g_NL_angular[n1 + N * i1];
      double x12double = g_x[n2] - x1;
      double y12double = g_y[n2] - y1;
      double z12double = g_z[n2] - z1;
      apply_mic(box, x12double, y12double, z12double);
      float x12 = float(x12double), y12 = float(y12double), z12 = float(z12double);
      float d12 = sqrt(x12 * x12 + y12 * y12 + z12 * z12);
      float fc12;
      find_fc(paramb.rc_angular, paramb.rcinv_angular, d12, fc12);
      fc12 *= atomic_number_n1 * g_atomic_number[n2];
      float fn12[MAX_NUM_N];
      find_fn(paramb.n_max_angular, paramb.rcinv_angular, d12, fc12, fn12);
      for (int i2 = 0; i2 < g_NN_angular[n1]; ++i2) {
        int n3 = g_NL_angular[n1 + N * i2];
        double x13double = g_x[n3] - x1;
        double y13double = g_y[n3] - y1;
        double z13double = g_z[n3] - z1;
        apply_mic(box, x13double, y13double, z13double);
        float x13 = float(x13double), y13 = float(y13double), z13 = float(z13double);
        float d13 = sqrt(x13 * x13 + y13 * y13 + z13 * z13);
        float fc13;
        find_fc(paramb.rc_angular, paramb.rcinv_angular, d13, fc13);
        fc13 *= atomic_number_n1 * g_atomic_number[n3];
        float cos123 = (x12 * x13 + y12 * y13 + z12 * z13) / (d12 * d13);
        float poly_cos[MAX_NUM_L];
        find_poly_cos(paramb.L_max, cos123, poly_cos);
        for (int n = 0; n <= paramb.n_max_angular; ++n) {
          for (int l = 1; l <= paramb.L_max; ++l) {
            q[(paramb.n_max_radial + 1) + (l - 1) * (paramb.n_max_angular + 1) + n] +=
              fn12[n] * fc13 * poly_cos[l];
          }
        }
      }
    }

    // nomalize descriptor
#ifdef CHECK_DESCRIPTOR
    float q_error = 0.0f;
#endif
    for (int d = 0; d < annmb.dim; ++d) {
      q[d] = (q[d] - paramb.q_min[d]) * paramb.q_scaler[d];
#ifdef CHECK_DESCRIPTOR
      if (q[d] > 1.0f) {
        q_error += q[d] - 1.0f;
      } else if (q[d] < 0.0f) {
        q_error -= q[d];
      }
#endif
    }
#ifdef CHECK_DESCRIPTOR
    if (q_error > annmb.dim * 0.01f) {
      printf("relative error q[%d] = %g% > 1%\n", n1, 100.0f * q_error / annmb.dim);
    }
#endif

    // get energy and energy gradient
    float F = 0.0f, Fp[MAX_DIM] = {0.0f};
    if (annmb.num_neurons2 == 0) {
      apply_ann_one_layer(annmb, q, F, Fp);
    } else {
      apply_ann(annmb, q, F, Fp);
    }

    g_pe[n1] += F;

    for (int d = 0; d < annmb.dim; ++d) {
      Fp[d] *= paramb.q_scaler[d];
      g_Fp[d * N + n1] = Fp[d];
    }
  }
}

static __global__ void find_force_radial(
  NEP2::ParaMB paramb,
  NEP2::ANN annmb,
  const int N,
  const int N1,
  const int N2,
  const Box box,
  const int* g_NN,
  const int* g_NL,
  const float* __restrict__ g_atomic_number,
  const double* __restrict__ g_x,
  const double* __restrict__ g_y,
  const double* __restrict__ g_z,
  const float* __restrict__ g_Fp,
  double* g_fx,
  double* g_fy,
  double* g_fz,
  double* g_virial)
{
  int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1;
  if (n1 < N2) {
    float atomic_number_n1 = g_atomic_number[n1];
    float s_fx = 0.0f;
    float s_fy = 0.0f;
    float s_fz = 0.0f;
    float s_sxx = 0.0f;
    float s_sxy = 0.0f;
    float s_sxz = 0.0f;
    float s_syx = 0.0f;
    float s_syy = 0.0f;
    float s_syz = 0.0f;
    float s_szx = 0.0f;
    float s_szy = 0.0f;
    float s_szz = 0.0f;
    double x1 = g_x[n1];
    double y1 = g_y[n1];
    double z1 = g_z[n1];
    for (int i1 = 0; i1 < g_NN[n1]; ++i1) {
      int n2 = g_NL[n1 + N * i1];
      float atomic_number_n12 = atomic_number_n1 * g_atomic_number[n2];
      double x12double = g_x[n2] - x1;
      double y12double = g_y[n2] - y1;
      double z12double = g_z[n2] - z1;
      apply_mic(box, x12double, y12double, z12double);
      float r12[3] = {float(x12double), float(y12double), float(z12double)};
      float d12 = sqrt(r12[0] * r12[0] + r12[1] * r12[1] + r12[2] * r12[2]);
      float d12inv = 1.0f / d12;
      float fc12, fcp12;
      find_fc_and_fcp(paramb.rc_radial, paramb.rcinv_radial, d12, fc12, fcp12);
      float fn12[MAX_NUM_N];
      float fnp12[MAX_NUM_N];
      find_fn_and_fnp(paramb.n_max_radial, paramb.rcinv_radial, d12, fc12, fcp12, fn12, fnp12);
      float f12[3] = {0.0f};
      float f21[3] = {0.0f};
      for (int n = 0; n <= paramb.n_max_radial; ++n) {
        float tmp12 = g_Fp[n1 + n * N] * fnp12[n] * atomic_number_n12 * d12inv;
        float tmp21 = g_Fp[n2 + n * N] * fnp12[n] * atomic_number_n12 * d12inv;
        for (int d = 0; d < 3; ++d) {
          f12[d] += tmp12 * r12[d];
          f21[d] -= tmp21 * r12[d];
        }
      }
      s_fx += f12[0] - f21[0];
      s_fy += f12[1] - f21[1];
      s_fz += f12[2] - f21[2];
      s_sxx += r12[0] * f21[0];
      s_sxy += r12[0] * f21[1];
      s_sxz += r12[0] * f21[2];
      s_syx += r12[1] * f21[0];
      s_syy += r12[1] * f21[1];
      s_syz += r12[1] * f21[2];
      s_szx += r12[2] * f21[0];
      s_szy += r12[2] * f21[1];
      s_szz += r12[2] * f21[2];
    }
    g_fx[n1] += s_fx;
    g_fy[n1] += s_fy;
    g_fz[n1] += s_fz;
    // save virial
    // xx xy xz    0 3 4
    // yx yy yz    6 1 5
    // zx zy zz    7 8 2
    g_virial[n1 + 0 * N] += s_sxx;
    g_virial[n1 + 1 * N] += s_syy;
    g_virial[n1 + 2 * N] += s_szz;
    g_virial[n1 + 3 * N] += s_sxy;
    g_virial[n1 + 4 * N] += s_sxz;
    g_virial[n1 + 5 * N] += s_syz;
    g_virial[n1 + 6 * N] += s_syx;
    g_virial[n1 + 7 * N] += s_szx;
    g_virial[n1 + 8 * N] += s_szy;
  }
}

static __global__ void find_partial_force_angular(
  NEP2::ParaMB paramb,
  const int N,
  const int N1,
  const int N2,
  const Box box,
  const int* g_NN_angular,
  const int* g_NL_angular,
  const float* __restrict__ g_atomic_number,
  const double* __restrict__ g_x,
  const double* __restrict__ g_y,
  const double* __restrict__ g_z,
  float* g_Fp,
  double* g_f12x,
  double* g_f12y,
  double* g_f12z)
{
  int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1;
  if (n1 < N2) {
    float atomic_number_n1 = g_atomic_number[n1];
    double x1 = g_x[n1];
    double y1 = g_y[n1];
    double z1 = g_z[n1];
    for (int i1 = 0; i1 < g_NN_angular[n1]; ++i1) {
      int index = i1 * N + n1;
      int n2 = g_NL_angular[n1 + N * i1];
      double x12double = g_x[n2] - x1;
      double y12double = g_y[n2] - y1;
      double z12double = g_z[n2] - z1;
      apply_mic(box, x12double, y12double, z12double);
      float r12[3] = {float(x12double), float(y12double), float(z12double)};
      float d12 = sqrt(r12[0] * r12[0] + r12[1] * r12[1] + r12[2] * r12[2]);
      float d12inv = 1.0f / d12;
      float fc12, fcp12;
      find_fc_and_fcp(paramb.rc_angular, paramb.rcinv_angular, d12, fc12, fcp12);
      float atomic_number_n12 = atomic_number_n1 * g_atomic_number[n2];
      fc12 *= atomic_number_n12;
      fcp12 *= atomic_number_n12;
      float fn12[MAX_NUM_N];
      float fnp12[MAX_NUM_N];
      find_fn_and_fnp(paramb.n_max_angular, paramb.rcinv_angular, d12, fc12, fcp12, fn12, fnp12);
      float f12[3] = {0.0f};
      for (int i2 = 0; i2 < g_NN_angular[n1]; ++i2) {
        int n3 = g_NL_angular[n1 + N * i2];
        double x13double = g_x[n3] - x1;
        double y13double = g_y[n3] - y1;
        double z13double = g_z[n3] - z1;
        apply_mic(box, x13double, y13double, z13double);
        float x13 = float(x13double), y13 = float(y13double), z13 = float(z13double);
        float d13 = sqrt(x13 * x13 + y13 * y13 + z13 * z13);
        float d13inv = 1.0f / d13;
        float fc13;
        find_fc(paramb.rc_angular, paramb.rcinv_angular, d13, fc13);
        fc13 *= atomic_number_n1 * g_atomic_number[n3];
        float cos123 = (r12[0] * x13 + r12[1] * y13 + r12[2] * z13) / (d12 * d13);
        float fn13[MAX_NUM_N];
        find_fn(paramb.n_max_angular, paramb.rcinv_angular, d13, fc13, fn13);
        float poly_cos[MAX_NUM_L];
        float poly_cos_der[MAX_NUM_L];
        find_poly_cos_and_der(paramb.L_max, cos123, poly_cos, poly_cos_der);
        float cos_der[3] = {
          x13 * d13inv - r12[0] * d12inv * cos123, y13 * d13inv - r12[1] * d12inv * cos123,
          z13 * d13inv - r12[2] * d12inv * cos123};
        for (int n = 0; n <= paramb.n_max_angular; ++n) {
          float tmp_n_a = (fnp12[n] * fn13[0] + fnp12[0] * fn13[n]) * d12inv;
          float tmp_n_b = (fn12[n] * fn13[0] + fn12[0] * fn13[n]) * d12inv;
          for (int l = 1; l <= paramb.L_max; ++l) {
            int nl = (paramb.n_max_radial + 1) + (l - 1) * (paramb.n_max_angular + 1) + n;
            float tmp_nl_a = g_Fp[nl * N + n1] * tmp_n_a * poly_cos[l];
            float tmp_nl_b = g_Fp[nl * N + n1] * tmp_n_b * poly_cos_der[l];
            for (int d = 0; d < 3; ++d) {
              f12[d] += tmp_nl_a * r12[d] + tmp_nl_b * cos_der[d];
            }
          }
        }
      }
      g_f12x[index] = f12[0];
      g_f12y[index] = f12[1];
      g_f12z[index] = f12[2];
    }
  }
}

void NEP2::compute(
  const int type_shift,
  const Box& box,
  const Neighbor& neighbor,
  const GPU_Vector<int>& type,
  const GPU_Vector<double>& position_per_atom,
  GPU_Vector<double>& potential_per_atom,
  GPU_Vector<double>& force_per_atom,
  GPU_Vector<double>& virial_per_atom)
{
  const int BLOCK_SIZE = 64;
  const int N = type.size();
  const int grid_size = (N2 - N1 - 1) / BLOCK_SIZE + 1;

  find_neighbor_angular<<<grid_size, BLOCK_SIZE>>>(
    paramb, N, N1, N2, box, neighbor.NN_local.data(), neighbor.NL_local.data(),
    position_per_atom.data(), position_per_atom.data() + N, position_per_atom.data() + N * 2,
    nep_data.NN.data(), nep_data.NL.data());
  CUDA_CHECK_KERNEL

  find_descriptor<<<grid_size, BLOCK_SIZE>>>(
    paramb, annmb, N, N1, N2, box, neighbor.NN_local.data(), neighbor.NL_local.data(),
    nep_data.NN.data(), nep_data.NL.data(), nep_data.atomic_number.data(), position_per_atom.data(),
    position_per_atom.data() + N, position_per_atom.data() + N * 2, potential_per_atom.data(),
    nep_data.Fp.data());
  CUDA_CHECK_KERNEL

  find_force_radial<<<grid_size, BLOCK_SIZE>>>(
    paramb, annmb, N, N1, N2, box, neighbor.NN_local.data(), neighbor.NL_local.data(),
    nep_data.atomic_number.data(), position_per_atom.data(), position_per_atom.data() + N,
    position_per_atom.data() + N * 2, nep_data.Fp.data(), force_per_atom.data(),
    force_per_atom.data() + N, force_per_atom.data() + N * 2, virial_per_atom.data());
  CUDA_CHECK_KERNEL

  find_partial_force_angular<<<grid_size, BLOCK_SIZE>>>(
    paramb, N, N1, N2, box, nep_data.NN.data(), nep_data.NL.data(), nep_data.atomic_number.data(),
    position_per_atom.data(), position_per_atom.data() + N, position_per_atom.data() + N * 2,
    nep_data.Fp.data(), nep_data.f12x.data(), nep_data.f12y.data(), nep_data.f12z.data());
  CUDA_CHECK_KERNEL
  find_properties_many_body(
    box, nep_data.NN.data(), nep_data.NL.data(), nep_data.f12x.data(), nep_data.f12y.data(),
    nep_data.f12z.data(), position_per_atom, force_per_atom, virial_per_atom);
  CUDA_CHECK_KERNEL
}
