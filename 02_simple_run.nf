/*
 *This is a nextflow workflow to analyze metagenomic datasets.
 * Steps involve quality control, quality trimming, calculation of sequencing depth based on the complexity of the metagenome
 * Calculation of average genome sizes for the metagenomes, calculation of Jaccard distances using Hulk to seperate samples.
 * Taxonomic classification with Kraken 2.
 * 
 */

/* 
 * pipeline input parameters 
 */

log.info """\
         METAGENOMICS - N F   P I P E L I N E    
         ===================================
         
         input - reads                  : ${params.reads}
         files in read set              : ${params.setsize}
         output - directory             : ${params.outdir}
         temporary - directory          : ${workDir}
         Trimmomatic adapters           : ${params.adapters} 
         Trimmomatic adapters directory : ${params.adapter_dir}
         phix - directory               : ${params.phix_dir} 
         host - directory               : ${params.host_dir}
         Kraken2 db -directory          : ${params.kraken2.path}
         Kraken2 db name                : ${params.kraken2_dir}
         """
         .stripIndent()

// Needed to run on the Saga HPC cluster !!!! NO LONGER NEEDED 
//preCmd = """
//if [ -f /cluster/bin/jobsetup ];  
//then set +u; source /cluster/bin/jobsetup; set -u; fi
///"""

// Creating the channels needed for the first analysis step
Channel 
    .fromFilePairs( params.reads, size:params.setsize, checkIfExists: true )
    .set { read_pairs_ch } 
 
/* running trimmomatic to remove adapters sequences
 * $task.cpus to specify cpus to use
 */ 

process run_trim {
    conda 'conda_yml/trimmomatic_env.yml'
    tag { pair_id }

    executor='slurm'
    label 'medium'

    input:
    set pair_id, file(reads) from read_pairs_ch

    output:
    set pair_id, file("${pair_id}_R{1,2}.trimmed.fq.gz") into reads_trimmed_ch
    file "${pair_id}_trimmed.log"

    """
    
    trimmomatic PE -threads $task.cpus -trimlog ${pair_id}_trimmed.log ${pair_id}*.gz \
    -baseout ${pair_id}_trimmed.fq.gz ILLUMINACLIP:${params.adapter_dir}/${params.adapters}:${params.illuminaClipOptions} \
    SLIDINGWINDOW:${params.slidingwindow} \
    LEADING:${params.leading} TRAILING:${params.trailing} \
    MINLEN:${params.minlen} &> ${pair_id}_run.log
    mv ${pair_id}_trimmed_1P.fq.gz ${pair_id}_R1.trimmed.fq.gz
    mv ${pair_id}_trimmed_2P.fq.gz ${pair_id}_R2.trimmed.fq.gz
    cat ${pair_id}_trimmed_1U.fq.gz ${pair_id}_trimmed_2U.fq.gz > ${pair_id}_S_concat_stripped_trimmed.fq.gz
    
    """
}

/*
 * remove low-complexity reads from datasets with bbduk
 */
process run_low_complex {
    conda 'conda_yml/bbmap_env.yml'

    tag { pair_id }
    
    executor='slurm'
    label 'medium'
    
    input:
    set pair_id, file(reads) from reads_trimmed_ch

    output:
    set pair_id, file("${pair_id}*.trimmed.highC.fq.gz") into reads_highC_ch
    file "${pair_id}_bbduk_output.log"

    """
    
    bbduk.sh threads=$task.cpus entropy=0.7 entropywindow=50 entropyk=5 \
    in1=${pair_id}_R1.trimmed.fq.gz \
    in2=${pair_id}_R2.trimmed.fq.gz \
    outm=${pair_id}.lowC.reads.fq.gz \
    out1=${pair_id}_R1.trimmed.highC.fq.gz \
    out2=${pair_id}_R2.trimmed.highC.fq.gz \
    stats=stats.txt &> ${pair_id}_bbduk_output.log
    
    """
}

/*
 * remove reads matching to phiX with bbduk
 */
process remove_phiX {
    conda 'conda_yml/bbmap_env.yml'
    
    tag { pair_id }
    
    executor='slurm'
    label 'medium'
    
    input:
    set pair_id, file(reads) from reads_highC_ch

    output:
    set pair_id, file("${pair_id}*.trimmed.highC.phix.fq.gz") into reads_phix_ch
    file "${pair_id}_bbduk_output.log"

    """
    
    bbduk.sh threads=$task.cpus ref=${params.phix_dir}/${params.phix_file} k=31 hdist=1 \
    in1=${pair_id}_R1.trimmed.highC.fq.gz \
    in2=${pair_id}_R2.trimmed.highC.fq.gz\
    outm=${pair_id}.phix.reads.fq.gz \
    out1=${pair_id}.R1.trimmed.highC.phix.fq.gz \
    out2=${pair_id}.R2.trimmed.highC.phix.fq.gz \
    stats=stats.txt &> ${pair_id}_bbduk_output.log
    
    """
}

/*
 * remove reads matching to human genome with bbmap
 */

process remove_host {
    conda 'conda_yml/bbmap_env.yml'
    publishDir "${params.outdir}/03_clean_data", mode: "${params.savemode}"
    tag { pair_id }
    
    executor='slurm'
    label 'large'

    input:
    set pair_id, file(reads) from reads_phix_ch

    output:
    set pair_id, file("${pair_id}.R{1,2}.clean.fq.gz") into  clean_data_ch1,
          clean_data_ch2, clean_data_ch3, clean_data_ch4, clean_data_ch5
    file "${pair_id}.*.human.fq.gz"
    file "${pair_id}_bbmap_output.log"

    """
    
    bbmap.sh -Xmx30g threads=$task.cpus \
    minid=0.95 maxindel=3 bwr=0.16 bw=12 \
    quickmatch fast minhits=2 \
    ref=${params.host_dir}/${params.host_file} \
    in=${pair_id}.R1.trimmed.highC.phix.fq.gz\
    in2=${pair_id}.R2.trimmed.highC.phix.fq.gz \
    outu=${pair_id}.R1.clean.fq.gz \
    outu2=${pair_id}.R2.clean.fq.gz \
    outm=${pair_id}.R1.human.fq.gz \
    outm2=${pair_id}.R2.human.fq.gz \
    statsfile=${pair_id}.human_result.txt &> ${pair_id}_bbmap_output.log
    
    """
}

/* Run fastqc, Multi qc for quality control of the final cleaned datasets
*/

process fastqc {
    conda 'conda_yml/fastqc_env.yml'

    publishDir "${params.outdir}/04_Cleaned_fastqc", mode: "copy"
    
    tag "FASTQC on $sample_id"
    
    executor='slurm'
    label 'small'

    input:
    set sample_id, file(reads) from clean_data_ch1

    output:
    file("fastqc_${sample_id}_logs") into fastqc_clean_ch


    script:
    """
    
    mkdir fastqc_${sample_id}_logs
    fastqc -o fastqc_${sample_id}_logs -f fastq -q ${reads}
    
    """  
}  
 
// running multiqc on the fastqc files from the channel: fastqc_clean_ch

process multiqc {
    conda 'conda_yml/multiqc_env.yml'
    publishDir "${params.outdir}/05_Cleaned_multiqc", mode: "${params.savemode}"
    
    executor='slurm'
    label 'small'

    input:
    file('*') from fastqc_clean_ch.collect()
    
    output:
    file('raw_data.multiqc_report.html')  
     
    script:
    """
    
    multiqc . 
    mv multiqc_report.html raw_data.multiqc_report.html
    
    """
} 

/************************************************************
*********  Data analysis of clean data **********************
*************************************************************/


/*
 * Calculate the sequence coverage of the metagenomes
 * I only use the forward reads of the dataset, because the presence of the same kmer in the reverse reads
 * can create a diversity estimate that is incorrect.
 */
process run_coverage {
    conda 'conda_yml/nonpareil_env.yml'
    publishDir "${params.outdir}/06_nonpareil", mode: "${params.savemode}"
    tag { pair_id }

    executor='slurm'
    label 'large'
    

    input:
    set pair_id, file(reads) from clean_data_ch2

    output:
    file("${pair_id}*.npo") into r_plotting_ch
    file "${pair_id}*.npa"
    file "${pair_id}*.npc"
    file "${pair_id}*.npl"
    file "${pair_id}*.npo"
    
    

    """
    echo only processing file: ${reads[0]}
    
    gunzip -c ${reads[0]} > forward_reads.fastq

    nonpareil -s forward_reads.fastq -T kmer -f fastq -b ${pair_id}_R1 \
     -X ${params.query} -n ${params.subsample} -t $task.cpus

     #cleanup area
     rm -r forward_reads.fastq
    
    """
}

/*
 * Create coverage calculations plots and combine into single html document
 */

 process plot_coverage {
    conda 'conda_yml/nonpareil_env.yml'
    publishDir "${params.outdir}/07_coverage_plots_clean_data", mode: "${params.savemode}"
    tag { "all samples" }

    executor='slurm'
    label 'small'

    input:
    file('*') from r_plotting_ch.collect()

    output:
    file "*.png"
    file "single_plots"   // folder with single file results

    """
    
    mkdir single_plots
    Rscript $baseDir/Rscripts/process_npo_files.r
    
    """
}


/* Calculate average genome size using microbecensus
 * Multithreading is functional after testing.
 * cpu usage is set to the "medium" queue.
 * to reduce the time used for this step, I reduce the number of reads sampled
 * Using 5.000.000 reads to calculate the AVG.
 * added the verbose option to see the settings when running.

 */

process Average_gsize {
    conda 'conda_yml/microbecensus_env.yml'
    publishDir "${params.outdir}/08_average_genome_size", mode: "${params.savemode}"
    tag { pair_id }

    executor='slurm'
    label 'medium'
   

    input:
    set pair_id, file(reads) from clean_data_ch3

    output:
    file ("${pair_id}*.txt") into avg_plot_ch
    
    """
    
    run_microbe_census.py -n 5000000 -t $task.cpus -v \
     ${pair_id}.R1.clean.fq.gz,${pair_id}.R2.clean.fq.gz \
     ${pair_id}.avgs_estimate.txt

    """
}

process plot_avgsizes {
    conda 'conda_yml/microbecensus_env.yml'
    publishDir "${params.outdir}/09_average_genome_size_plots", mode: "${params.savemode}"
    tag { "all_samples" }

    executor='slurm'
    label 'small'

    input:
    file("*") from avg_plot_ch.collect()

    output:
    file "*.pdf"

    """
    
    Rscript $baseDir/Rscripts/create_AVGsize_plots.r
    
    """
}


/* Calculate hulk sketches of each clean dataset */

process hulk_calculation {
    conda 'conda_yml/hulk_env.yml'
    publishDir "${params.outdir}/10_hulk_distances", mode: "${params.savemode}"
    tag { "all samples" }

    executor='slurm'
    label 'medium'

    input:
    set pair_id, file(reads) from clean_data_ch4

    output:
    file ("${pair_id}*.json") into hulk_distance_ch
    
    """
    
    gunzip -f ${pair_id}.R*.clean.fq.gz
    cat ${pair_id}.R*.clean.fq > ${pair_id}.clean.fq

    hulk sketch -k 31 -p $task.cpus \
        -f ${pair_id}.clean.fq -o ${pair_id}.R12 
    rm -r *.fq
    
    """
}

/* Calculate hulk distances of all vs all datasets */

process hulk_distance {
    conda 'conda_yml/hulk_env.yml'
    publishDir "${params.outdir}/11_hulk_heatmap", mode: "${params.savemode}"
    tag { "all samples" }

    executor='slurm'
    label 'small'

    input:
    file ("*") from hulk_distance_ch.collect()

    output:
    file "*.pdf"
    file("all_samples.Weighted_Jaccard.hulk-matrix.csv")
    
    """
    
    hulk smash -k 31 -m weightedjaccard -d ./ -o all_samples.Weighted_Jaccard
    Rscript $baseDir/Rscripts/create_hulk_heatmap.r
    
    """
}


process Kraken_classification {
    conda 'conda_yml/kraken2_env.yml'
    publishDir "${params.outdir}/12_kraken2_classification", mode: "${params.savemode}"
    tag { "all samples" }

    executor='slurm'
    label 'bigmem'

    input:
    set pair_id, file(reads) from clean_data_ch5

    output:
    file "*"
    

    """
    #gunzip -f *.fq.gz
    
    kraken2 -v
    
    kraken2 -db ${params.kraken2.path}/${params.kraken2_dir} \
    --threads $task.cpus \
    --minimum-base-quality 20 \
    --gzip-compressed \
    --output ${pair_id}.kr2.out \
    --report ${pair_id}.kr2.report \
    --classified-out ${pair_id}.classified.R#.fastq.gz  \
    --unclassified-out ${pair_id}.unclassified.R#.fastq.gz \
    --paired \
    ${pair_id}.R1.clean.fq.gz ${pair_id}.R2.clean.fq.gz

    ls -lah

    #removing dataset that are not needed
    rm -r *.classified.R*.fastq.gz
    rm -r *.unclassified.R*.fastq.gz

    #compressing the *.out file
    gzip *.out

    #checking the files left
    ls -la

    """
}
