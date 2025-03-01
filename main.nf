#!/usr/bin/env nextflow

// Developer notes
// 
// This template workflow provides a basic structure to copy in order
// to create a new workflow. Current recommended pratices are:
//     i) create a simple command-line interface.
//    ii) include an abstract workflow scope named "pipeline" to be used
//        in a module fashion.
//   iii) a second concreate, but anonymous, workflow scope to be used
//        as an entry point when using this workflow in isolation.

import groovy.json.JsonBuilder
import nextflow.util.BlankSeparatedList;
nextflow.enable.dsl = 2

include { fastq_ingress } from './lib/fastqingress'
include { start_ping; end_ping } from './lib/ping'


// def addSampleNameCol()

process summariseReads {
    // concatenate fastq and fastq.gz in a dir

   label "cas9"
    cpus 1
    input:
        tuple path(directory), val(sample_id), val(type)
    output:
        tuple val(sample_id), path("${sample_id}.stats"), emit: stats
        tuple val(sample_id), path("${sample_id}.fastq"), emit: reads

    shell:
    """
    fastcat -s ${sample_id} -r ${sample_id}.stats -x ${directory} > "${sample_id}.fastq"
    """
}


process getVersions {
   label "cas9"
    cpus 1
    output:
        path "versions.txt"
    script:
    """
    python -c "import pysam; print(f'pysam,{pysam.__version__}')" >> versions.txt
    fastcat --version | sed 's/^/fastcat,/' >> versions.txt
    """
}


process getParams {
   label "cas9"
    cpus 1
    output:
        path "params.json"
    script:
        def paramsJSON = new JsonBuilder(params).toPrettyString()
    """
    # Output nextflow params object to JSON
    echo '$paramsJSON' > params.json
    """
}

process make_tiles {
    label 'cas9'
    input:
        path chrom_sizes
        path targets
    output:
        path 'tiles.bed', emit: tiles
        path 'tiles_int_targets.bed', emit: tiles_inter_targets
    script:
    """
    bedtools makewindows -g $chrom_sizes -w 100 -i 'srcwinnum' | gzip > tiles.bed
    bedtools intersect -a tiles.bed -b $targets -wb > tiles_int_targets.bed
    """
}

process build_index{
    /*
    Build minimap index from reference genome
    */
    label "cas9"
    cpus params.threads

    input:
        file reference
    output:
        path "genome_index.mmi", emit: index
        path "chrom.sizes", emit: chrom_sizes
    script:
    """
        minimap2 -t $params.threads -x map-ont -d genome_index.mmi $reference
        samtools faidx $reference
        cut -f 1,2 ${reference}.fai >> chrom.sizes
    """
}

process align_reads {
    /*
    TODO: The number of off-target is quite a lot higher than in the tutorial
    Tutorial uses mini_align rather than minimap2 directly.

    mini_align \
    -r "$reference_genome" -i "$input_file" \
    -p "$output_folder/alignments" \
    -t 4 -m
    */
    label "cas9"
    input:
        path index
        path reference
        tuple val(sample_id), path(fastq_reads)
    output:
        tuple val(sample_id), path("${sample_id}.bam"), path("${sample_id}.bam.bai"), emit: bam
        tuple val(sample_id), path("${sample_id}_fastq_pass.bed"), emit: bed
    script:
    """
    minimap2 -t $params.threads -m 4 -ax map-ont $index $fastq_reads | samtools sort -o ${sample_id}.bam -O BAM -
    samtools index ${sample_id}.bam
    bedtools bamtobed -i ${sample_id}.bam | bedtools sort > ${sample_id}_fastq_pass.bed
    """
}

process target_coverage {
    /* Call the python processing script and get back CSVs that will be used in the report
    emits
        target_coverage: tiled csv for creating plots
    # NOTE
    use \W\+\W as strand may move columns in future versions

    emits tsv with these columns
        chr start end target cov_f cov_r sample_id

     */
    label "cas9"
    input:
        path targets
        path tiles
        path tiles_inter_targets
        path chrom_sizes
        tuple val(sample_id),
              path(aln)
    output:
        path('*_target_cov.bed'), emit: target_coverage


    script:
    """
    # Get alignment coverage at tiles per strand

    if grep -q "\\W+" $aln
      then
        cat $aln | grep "\\W+" | bedtools coverage -a $tiles_inter_targets -b - | \
            cut -f 1,2,3,8,9 > pos.bed
      else
        echo "_\t0\t1\ttest_id\t0\t+" > p.bed
        cat p.bed| grep "\\W+" | bedtools coverage -a $tiles_inter_targets -b - | \
            cut -f 1,2,3,8,9 > pos.bed
    fi

    if grep -q "\\W-" $aln
      then
        cat $aln | grep "\\W-" | bedtools coverage -a $tiles_inter_targets -b - | \
            cut -f 9 > neg.bed
      else
        echo "_\t0\t1\ttest_id\t0\t-\n" > n.bed;
        cat n.bed | grep "\\W-" | bedtools coverage -a $tiles_inter_targets -b - | \
            cut -f 9 > neg.bed
    fi

    # Cols ["chr", "start", "end", "target", "coverage_f", 'coverage_r']
    paste pos.bed neg.bed > ${sample_id}_target_cov.bed

    # Add sample_id column
    sed "s/\$/\t${sample_id}/" ${sample_id}_target_cov.bed > tmp
    mv tmp ${sample_id}_target_cov.bed

    rm pos.bed neg.bed
    """

}

process target_summary {
    /*
    Make a target summary bed file with a row per target. Columns:
        chr,
        start,
        end,
        target,
        number of reads,
        num bases covered,
        target length,
        fracTargAln,
        medianCov,
        num positive
        strand reads,
        num negative,
        strand reads
    */
    label "cas9"
    input:
        path targets
        path tiles
        path tiles_inter_targets
        path chrom_sizes
        tuple val(sample_id),
              path(aln)
    output:
        path('*_target_summary.bed'), emit: table
    script:
    """
    # Map targets to aln.
    # If the output is empty, there are no reads intersecting targets. In this case output an empty table file
    cat $aln | bedtools intersect -a - -b $targets -wb > aln_targets.bed

    # chr, start, stop (target), target, overlaps, covered_bases, len(target), frac_covered
    # This forms first few columns of output table
    bedtools coverage -a $targets -b $aln > target_summary_temp.bed

    # Get alignment coverage at tiles per strand
    cat $aln | bedtools coverage -a $tiles_inter_targets -b -  > target_cov.bed

    # Get median coverage (col 9) by target (col 8)

    bedtools groupby -i target_cov.bed -g 8 -c 9 -o median | cut -f 2  > median_coverage.bed

    # Strand bias

    cat aln_targets.bed | grep "\\W+\\W" | bedtools coverage -b - -a $targets | cut -f 5  > pos.bed  || true

    cat aln_targets.bed | grep "\\W-\\W" | bedtools coverage -b - -a $targets | cut -f 5  > neg.bed || true

    paste target_summary_temp.bed \
        median_coverage.bed \
        pos.bed \
        neg.bed > ${sample_id}_target_summary.bed

    # Add sample_id column
    sed "s/\$/\t${sample_id}/" ${sample_id}_target_summary.bed > tmp
    mv tmp ${sample_id}_target_summary.bed

    rm median_coverage.bed pos.bed neg.bed
    """
}

process coverage_summary {
    label "cas9"
    input:
        path targets
        tuple val(sample_id),
              path(aln)
    output:
        path('*on_off_summ.csv'), emit: summary
        path('*on_off.bed'), emit: on_off
        tuple val(sample_id), path('*on.bed'), emit: on
    script:
    """
    # For table with cols:  num_reads, num_bases, mean read_len
    bedtools intersect -a $aln -b $targets -wa -wb -v | cut -f 1-4 | \
     awk -F '\\t' -v OFS='\\t' '{ \$(NF+1) = OFF; print }'  > off.bed
    bedtools intersect -a $aln -b $targets -wa -wb | cut -f 1-4,10  > on.bed

    numread_on=\$(cat on.bed | wc -l | tr -d ' ')
    numread_off=\$(cat off.bed | wc -l | tr -d ' ')

    cat on.bed off.bed > ${sample_id}_on_off.bed

    bases_on=\$(cat on.bed   | awk -F'\t' 'BEGIN{SUM=0}{ SUM+=\$3-\$2 }END{print SUM}')
    bases_off=\$(cat off.bed | awk -F'\t' 'BEGIN{SUM=0}{ SUM+=\$3-\$2 }END{print SUM}')

    echo "\${numread_on}\t\${numread_off}\n\${bases_on}\t\${bases_off}" > ${sample_id}_on_off_summ.csv

    # Add sample id columns
    sed "s/\$/\t${sample_id}/" ${sample_id}_on_off_summ.csv > tmp1
    mv tmp1 ${sample_id}_on_off_summ.csv

    sed "s/\$/\t${sample_id}/" ${sample_id}_on_off.bed > tmp2
    mv tmp2 ${sample_id}_on_off.bed
    """
}

process background {
    label "cas9"
    input:
        path targets
        path tiles
        path chrom_sizes
        tuple val(sample_id),
              path(aln)
    output:
        path('*_tiles_background_cov.bed'), emit: table
        path('*off_target_hotspots.bed'), emit: hotspots
    script:
    """
    # Slop = padding of targets
    # remove reads that overlap slopped targets
    bedtools slop -i $targets -g $chrom_sizes -b 1000 | tee  targets_padded.bed | \
        bedtools intersect -v -a $aln -b - -wa | \
        bedtools coverage -a $tiles -b - > ${sample_id}_tiles_background_cov.bed

    # Get all contiguous regions of background alignments
    cat targets_padded.bed | bedtools intersect -a $aln -b - -v  | \
        bedtools merge -i - | bedtools coverage -a - -b $aln | \
        cut -f 1-4 > ${sample_id}_off_target_hotspots.bed

    # Add sample_id columns
    sed "s/\$/\t${sample_id}/" ${sample_id}_tiles_background_cov.bed > tmp1
    mv tmp1 ${sample_id}_tiles_background_cov.bed

    sed "s/\$/\t${sample_id}/" ${sample_id}_off_target_hotspots.bed > tmp2
    mv tmp2 ${sample_id}_off_target_hotspots.bed
    """
}


process get_on_target_reads {
    label "cas9"
    input:
        tuple val(sample_id),
              path(fastq),
              path(on_bed)
    output:
         tuple val(sample_id), path("${sample_id}_ontarget.fastq"), emit: fastq
    script:
    """
    cat $on_bed | cut -f 4 > seqids
    cat $fastq | seqkit grep -f seqids -o "${sample_id}_ontarget.fastq"
    """
}

process makeReport {
   label "cas9"
    input:
        path "versions/*"
        path "params.json"
        tuple val(sample_ids),
              path(seq_summaries)
        path target_coverage
        path target_summary_table
        path background
        path off_target_hotspots
        path coverage_summary
        path on_off

    output:
        path "wf-cas9-*.html", emit: report
    script:
        report_name = "wf-cas9-" + params.report_name + '.html'
        // Convert the sample_id arrayList.
        sids = new BlankSeparatedList(sample_ids)
        def opttcov = target_coverage.name.startsWith('OPTIONAL_FILE') ? '' : "--target_coverage ${target_coverage}"
        def optbcov = background.name.startsWith('OPTIONAL_FILE') ? '' : "--background ${background}"
        def optbghot = off_target_hotspots.name.startsWith('OPTIONAL_FILE') ? '' : "--off_target_hotspots ${off_target_hotspots}"

    """
    report.py $report_name \
        --summaries $seq_summaries \
        --versions versions \
        --params params.json \
        --target_summary $target_summary_table \
        --sample_ids $sids \
        --coverage_summary $coverage_summary \
        --on_off $on_off \
        ${opttcov} \
        ${optbcov} \
        ${optbghot}
    """
}

// See https://github.com/nextflow-io/nextflow/issues/1636
// This is the only way to publish files from a workflow whilst
// decoupling the publish from the process steps.
process output {
    // publish inputs to output directory
    label "cas9"
    publishDir "${params.out_dir}", mode: 'copy', pattern: "*"
    input:
        path fname
    output:
        path fname
    """
    echo "Writing output files"
    """
}


// workflow module
workflow pipeline {
    take:
        reads
        ref_genome
        targets
    main:
        build_index(ref_genome)
        summariseReads(reads)
        software_versions = getVersions()
        workflow_params = getParams()

        align_reads(
            build_index.out.index,
            ref_genome,
            summariseReads.out.reads)

        make_tiles(build_index.out.chrom_sizes,
            targets)

        coverage_summary(targets,
            align_reads.out.bed)

       get_on_target_reads(summariseReads.out.reads
            .join(coverage_summary.out.on))

        target_summary(targets,
            make_tiles.out.tiles,
            make_tiles.out.tiles_inter_targets,
            build_index.out.chrom_sizes,
            align_reads.out.bed)

        // No output in debug mode
        if (params.full_report){
            target_coverage(targets,
                make_tiles.out.tiles,
                make_tiles.out.tiles_inter_targets,
                build_index.out.chrom_sizes,
                align_reads.out.bed)

            background(targets,
                make_tiles.out.tiles,
                build_index.out.chrom_sizes,
                align_reads.out.bed)

            tar_cov_tsv = target_coverage.out.target_coverage.collectFile(name: 'target_coverage')
            bg_cov = background.out.table.collectFile(name: 'background')
            bg_hotspots = background.out.hotspots.collectFile(name: 'hotspots')

        }else {
            tar_cov_tsv = file("$projectDir/data/OPTIONAL_FILE")
            bg_cov = file("$projectDir/data/OPTIONAL_FILE1")
            bg_hotspots = file("$projectDir/data/OPTIONAL_FILE2")
        }

        report = makeReport(software_versions,
                    workflow_params,
                    summariseReads.out.stats.toList().transpose().toList(),
                    tar_cov_tsv,
                    target_summary.out.table.collectFile(name: 'target_summary'),
                    bg_cov,
                    bg_hotspots,
                    coverage_summary.out.summary.collectFile(name: 'coverage_summary'),
                    coverage_summary.out.on_off.collectFile(name: 'on_off'),
                    )

        results = get_on_target_reads.out
             .concat(summariseReads.out.stats)
             .map {it -> it[1]} // Remove sample id from tuples
             .concat(makeReport.out.report)
             .concat(align_reads.out.bam.map {it -> [ it[1], it[2] ]})

    emit:
        results
        telemetry = workflow_params
}


// entrypoint workflow
WorkflowMain.initialise(workflow, params, log)
workflow {
    start_ping()

    ref_genome = file(params.ref_genome, type: "file")
    if (!ref_genome.exists()) {
        println("--ref_genome: File doesn't exist, check path.")
        exit 1
    }
    targets = file(params.targets, type: "file")
    if (!targets.exists()) {
        println("--targets: File doesn't exist, check path.")
        exit 1
    }
    def line
    targets.withReader { line = it.readLine() }
    if (line.split("\t").size() != 4){
        println('Target file should have 4 cols: chr start end target_name')
        exit 1
    }

    samples = fastq_ingress(
        params.fastq, params.out_dir, params.sample, params.sample_sheet, params.sanitize_fastq)


    pipeline(samples, ref_genome, targets)
    output(pipeline.out.results)
    end_ping(pipeline.out.telemetry)
}
